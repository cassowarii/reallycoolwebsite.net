package linkgarden;
use strict;
use warnings;
use utf8;

use v5.16;

use Dancer2 appname => 'linkgarden';
use Dancer2::Plugin::Database;
use Dancer2::Plugin::Auth::Extensible;

use Encode;
use Parse::BBCode;

use util;

# Special Thanks https://corz.org/server/techniques/php/how-to-feed-rss.php

# send correct header..
get '/~:user/rss' => sub {
    my $username = route_parameters->get('user');

    my %ctparams = common_template_params({
        user => $username
    });

    my $stmt = entry_query('WHERE u.name = ?', 'ORDER BY l.created DESC LIMIT 15');

    $stmt->execute($username);

    # Raw link objects we got out of the DB.
    my @dblinks = @{$stmt->fetchall_arrayref({})};

    my @results = map { process_link_from_db($_) } @dblinks;

    my $title;

    response_header 'Content-Type' => 'application/rss+xml';

    template 'rss' => {
        %ctparams,
        results => [ @results ],
    }, {
        layout => undef,
    };
};
