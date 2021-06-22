package OpenAPI::From::DBIC;

use v5.24;

use strict;
use warnings;

use Moo;

use Software::LicenseUtils;
use YAML::PP;
use YAML::PP::Common qw/PRESERVE_ORDER/;

use feature 'signatures';
no warnings 'experimental::signatures';

has schema_module => ( is => 'ro' );
has servers       => ( is => 'ro' );
has license       => ( is => 'ro' );
has description   => ( is => 'ro' );
has version       => ( is => 'ro' );
has title         => ( is => 'ro' );
has tos           => ( is => 'ro' );
has email         => ( is => 'ro' );

sub generate ( $self ) {
    eval {
        my $path = ($self->schema_module =~ s{::}{/}gr) . '.pm';
        require $path;
    } or return $@;

    my $db = $self->schema_module->connect;

    my %info;

    $info{contact}->{email} = $self->email       if $self->email;
    $info{termsOfService}   = $self->tos         if $self->tos;
    $info{title}            = $self->title       if $self->title;
    $info{description}      = $self->description if $self->description;
    $info{version}          = $self->version     if $self->version;

    if ( $self->license ) {
        my $license = Software::LicenseUtils->new_from_short_name({
            short_name => $self->license,
            holder     => $self->email // 'a.non@test.tld',
        });

        if ( $license ) {
            $info{license} = +{
                name => $license->name,
                url  => $license->url,
            };
        }
    }

    my $ypp     = YAML::PP->new( preserve => PRESERVE_ORDER );
    my $openapi = $ypp->preserved_mapping({});

    $openapi->%* = (
        openapi    => '3.0.0',
        (%info ? ( info => \%info ) : () ),
        servers    => [ map { +{ url => $_ } } $self->servers->@* ],
        paths      => {},
        components => { schemas => {} },
    );

    my $reg = $db->source_registrations;
    for my $source ( keys $reg->%* ) {
        my $rs = $reg->{$source};
        $source = lc $source;

        my @id_columns = $rs->primary_columns;

        schemas( $source, $rs, \@id_columns, $openapi->{components}->{schemas} );

        if ( $rs->can('__openapi') ) {
            p $rs->__openapi;
        }

        my $base_path = '/' . $source;

        # create
        path( $base_path, $source, 'post', undef, $openapi->{paths} );

        # retrieve (list)
        path( $base_path, $source, 'list', undef, $openapi->{paths} );

        $base_path .= '/' . join '/', map{ ":$_" } @id_columns;

        # retrieve
        path( $base_path, $source, 'get', \@id_columns, $openapi->{paths} );

        # update
        path( $base_path, $source, 'patch', \@id_columns, $openapi->{paths} );

        # delete
        path( $base_path, $source, 'delete', \@id_columns, $openapi->{paths} );
    }

    return YAML::PP->new( preserve => PRESERVE_ORDER )->dump_string( $openapi );
}

sub path ( $path, $source, $method, $path_params, $paths ) {
    my %schema_mapping = (
        post   => [ 'create', 'response' ],
        patch  => [ 'create', 'response' ],
        get    => [ '',       'response' ],
        list   => [ '',       'list'     ],
        delete => [ '',       ''         ]
    );

    my ($input_schema, $response_schema) = map{
        $_ ? $source . '_' . $_ : undef;
    } $schema_mapping{$method}->@*;

    my $http_method = $method;
    $http_method    = 'get' if $method eq 'list';

    my %path_info;

    if ( $path_params ) {
        for my $param_name ( $path_params->@* ) {
            push $path_info{parameters}->@*, +{
                name => $param_name,
                in   => 'path',
                required => 'true',
            };
        }
    }

    if ( $input_schema ) {
        $path_info{requestBody} = {
            required => 'true',
            content => {
                'application/json' => {
                    '$ref' => '#/components/schemas/' . $input_schema,
                },
            },
        };
    }

    $path_info{reponses} = responses( $source, $method, $response_schema );

    $paths->{$path}->{$http_method} = {
        summary     => '',
        description => '',
        operationId => '',
        %path_info,
    };
}

sub responses ( $source, $method, $response_schema ) {
    my %response_mapping = (
        post   => [ 201, 400, 401, 403, 500 ],
        patch  => [ 201, 400, 401, 403, 404, 500 ],
        get    => [ 200, 400, 401, 403, 404, 500 ],
        list   => [ 200, 400, 401, 403, 404, 500 ],
        delete => [ 204, 400, 401, 403, 404, 500 ],
    );

    my %responses;

    for my $code ( $response_mapping{$method}->@* ) {
        $responses{$code} = +{
            description => '',
        };

        if ( ( $code == 200 || $code == 201 ) && $response_schema ) {
            $responses{$code}->{content} = +{
                'application/json' => {
                    schema => {
                        '$ref' => '#/components/schemas/' . $response_schema,
                    },
                },
            };
        }
    }

    return \%responses;
}

sub schemas ( $source, $rs, $id_columns, $schemas) {
    my %id_column_map = map { $_ => 1 } $id_columns->@*;

    my $columns  = $rs->columns_info;
    my @required = grep { !$columns->{$_}->{is_nullable} } keys $columns->%*;

    # response schema
    schema( 'response', $source, \@required, $columns, $schemas );

    # list schema
    schema( 'list', $source, undef, undef, $schemas );

    # create/update schema
    @required = grep { !$id_column_map{$_} } @required; 
    delete $columns->{$_} for keys %id_column_map;
    schema( 'create', $source, \@required, $columns, $schemas );
}

sub schema ( $type, $source, $required, $columns, $schemas ) {
    if ( $type eq 'list' ) {
        $schemas->{$source . '_list'} = +{
            type => 'array',
            items => {
                '$ref' => '#/components/schemas/' . $source
            }
        };

        return;
    }

    my %properties = properties( $columns );

    $schemas->{$source . '_' . $type} = +{
        type => 'object',
        ( $required && $required->@* ? ( required => $required ) : () ),
        properties => \%properties,
    };
}

sub properties ( $columns ) {
    my %properties;

    my %types = (
        varchar   => 'string',
        char      => 'string',
        decimal   => 'number',
        int       => 'integer',
        smallint  => 'integer',
        bigint    => 'integer',
        mediumint => 'integer',
        tinyint   => 'integer',
        numeric   => 'number',
        decimal   => [ 'number', 'double'    ],
        datetime  => [ 'string', 'date-time' ],
        date      => [ 'string', 'date'      ],
        bool      => 'boolean',
        blob      => [ 'string', 'binary' ],
        longblob  => [ 'string', 'binary' ],
        json      => 'string',
    );

    for my $col ( keys $columns->%* ) {
        my $datatype = $columns->{$col}->{data_type} || 'string';
        my $type_raw = $types{ $datatype } || 'string';

        my ($type, $format) = ref $type_raw ? $type_raw->@* : $type_raw;

        $properties{$col} = {
            type => $type,
            ( $format ? ( format => $format ) : () ),
        };
    }

    return %properties;
}

1;
