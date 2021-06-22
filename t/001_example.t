#!/usr/bin/perl

use strict;
use warnings;

use OpenAPI::From::DBIC;

use Data::Printer;
use File::Basename;
use Test::More;

use lib dirname(__FILE__) . '/data';

ok 1;

my $generator = OpenAPI::From::DBIC->new(
    license       => 'GPL-1',
    email         => 'a.uthor@example.tld',
    title         => 'TimePieceDB example',
    servers       => [ 'http://test.tld' ],
    version       => '1.0.0',
    schema_module => 'TimePieceDB',
);

my $yaml = $generator->generate;

p $yaml;

done_testing();
