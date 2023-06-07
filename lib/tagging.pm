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

get '/~:user/tag/:tagname/edit/?' => require_login sub {
    my $username = route_parameters->get('user');
    my $tagname = route_parameters->get('tagname');

    if ($username ne logged_in_user->{name}) {
        redirect '/'; # No permission
    }

    my $stmt = database('viewer')->prepare(
        'SELECT t.*, td.*, u.name username FROM linkgarden_tag_descs td
            INNER JOIN linkgarden_tags t ON td.tag_id = t.id
            INNER JOIN linkgarden_users u ON u.id = td.owner
            WHERE t.name = ? AND u.name = ?'
    );
    $stmt->execute($tagname, $username);
    my $tag = $stmt->fetchrow_hashref();
    $tag->{name} = $tagname;
    $tag->{description} = Encode::decode('utf8', $tag->{description});

    my %ctparams = common_template_params({
        user => $username
    });

    template 'edit_tag_desc' => {
        %ctparams,
        nav => [
            { name => "~$username", link => "/~$username" },
            { name => "tag", link => "/~$username/tag" },
            { name => $tagname, link => "/~$username/tag/$tagname" },
            { name => "edit", link => undef },
        ],
        title => "Editing tag '$tagname'",
        tag => $tag,
    };
};

post '/~:user/tag/:tagname/edit/?' => require_login sub {
    my $username = route_parameters->get('user');
    my $tagname = route_parameters->get('tagname');

    if ($username ne logged_in_user->{name}) {
        redirect '/'; # No permission
    }

    my $new_desc = body_parameters->get('description');

    # Get tag ID
    my $stmt = database('viewer')->prepare(
        'SELECT * FROM linkgarden_tags WHERE name = ?'
    );
    $stmt->execute($tagname);
    my $taginfo = $stmt->fetchrow_hashref();
    say {\*STDERR} "Found tag ID for $tagname: $taginfo->{id}";

    # Check for preexisting tag description
    $stmt = database('viewer')->prepare(
        'SELECT t.*, td.*, td.id desc_id, u.name username FROM linkgarden_tag_descs td
            INNER JOIN linkgarden_tags t ON td.tag_id = t.id
            INNER JOIN linkgarden_users u ON u.id = td.owner
            WHERE t.name = ? AND u.name = ?'
    );
    $stmt->execute($tagname, $username);
    my $descinfo = $stmt->fetchrow_hashref();

    if ($descinfo) {
        $stmt = database('link_creator')->prepare(
            'UPDATE linkgarden_tag_descs SET description = ? WHERE id = ?'
        );
        $stmt->execute($new_desc, $descinfo->{desc_id});
    } else {
        $stmt = database('link_creator')->prepare(
            'INSERT INTO linkgarden_tag_descs (owner, tag_id, description) VALUES (?, ?, ?)'
        );
        $stmt->execute(logged_in_user->{id}, $taginfo->{id}, $new_desc);
    }

    redirect "/~$username/tag/$tagname";
};

1;
