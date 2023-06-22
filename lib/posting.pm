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
use upload;

my @iconlist = (
    'flower', 'moon', 'music', 'tv', 'spiral',
    'tree', 'brain', 'magnifying', 'hourglass',
    'confusion', 'oh', 'ex', 'fish',
);

get '/formatting-guide/?' => sub {
    say {\*STDERR} "GETTING FOrMATTING GUIDE";
    template 'formatting_guide' => {
        common_template_params({
            color => 'blank',
        }),
        nav => [
            { name => "formatting guide", link => undef }
        ],
        title => "Formatting guide &mdash; reallycoolwebsite.net",
    };
};

get '/new-entry/?' => require_login sub {
    template 'post' => {
        common_template_params,
        nav => [
            { name => "new entry", link => undef }
        ],
        link => {
            icon => 'flower',
            enable_comments => logged_in_user->{enable_default_comments},
        },
        title => "New entry &mdash; reallycoolwebsite.net",
        icons => [ @iconlist ],
        form_title => 'New entry',
        img_url => undef,
    };
};

sub preview {
    my ($params, $form_title, $old_link, $img_url, $extra) = @_;
    my %extra = %$extra;

    my @preview_tags = fix_tags Encode::encode('utf8', $params->get('tags'));

    my $url = $params->get('url');
    my $preview_youtube;
    if ($url =~ m{^https?://(www\.)?youtube\.com/watch\?v=.+$}) {
        $url =~ m{/watch\?v=(.+)$};
        $preview_youtube = $1;
    } elsif ($url =~ m{^https?://(www\.)?youtu\.be/.+$}) {
        $url =~ m{/(.+)$};
        $preview_youtube = $1;
    }

    my $nav;
    if ($old_link) {
        my $link_name = $old_link->{name};
        $nav = [
            { name => "~$old_link->{username}", link => "/~$old_link->{username}" },
            { name => "all", link => "/~$old_link->{username}/all" },
            { name => $old_link->{name}, link => "/~$old_link->{username}/entry/$old_link->{id}" },
            { name => "edit", link => undef }
        ];
    } else {
        $nav = [
            { name => "new post", link => undef }
        ]
    }

    template 'post' => {
        common_template_params({}),
        nav => $nav,
        title => "$form_title &mdash; reallycoolwebsite.net",
        old_link => $old_link,
        link => {
            # Even though it looks like this is the same as { %$params },
            # don't simplify it to that because $params is the body_parameters,
            # not a 'link' object. So the mapping here may eventually change.
            name => $params->get('name'),
            url => $params->get('url'),
            description => $params->get('description'),
            tags => $params->get('tags'),
            icon => $params->get('icon'),
            enable_comments => $params->get('enable_comments'),
        },
        back_page => body_parameters->get('back_page'),
        post_type => $params->get('post_type'),
        do_preview => 1,
        preview_text => format_text($params->get('description'), logged_in_user->{name}),
        preview_tags => [ @preview_tags ],
        preview_youtube => $preview_youtube,
        icons => [ @iconlist ],
        form_title => $form_title,
        img_url => $img_url,
        %extra,
    };
}

post '/new-entry/?' => require_login sub {
    my $img_url;
    my $update_img;
    if (request->upload('image')) {
        say {\*STDERR} "We need to upload an image!";
        $update_img = 1;
        $img_url = handle_upload(request->upload('image'));
    } elsif (body_parameters->get('remove_attachment')) {
        # Remove attached image
        $update_img = 1;
        $img_url = '';
    } elsif (body_parameters->get('actually_existing_image')) {
        $update_img = 1;
        $img_url = body_parameters->get('actually_existing_image');
    }

    unless (body_parameters->get('save')) {
        return preview(body_parameters, 'New entry', undef, $img_url, {});
    }

    # Okay, we're saving it
    my $user = logged_in_user;
    my $name = body_parameters->get('name');
    my $icon = body_parameters->get('icon');
    my $description = body_parameters->get('description');
    my $enable_comments = defined body_parameters->get('enable_comments') || 0;

    my @tags = fix_tags Encode::encode('utf8', body_parameters->get('tags'));

    my $url;
    if (body_parameters->get('post_type') eq 'link') {
        $url = body_parameters->get('url');
        eval {
            die "Please provide a link!\n" unless $url;
            validate_link $url;
        }; if (my $error = $@) {
            return preview(body_parameters, 'New entry', undef, $img_url, {
                flash_icon => 'error',
                flash_msg => $error,
            });
        }
    } else {
        $url = 'self';
    }

    my $stmt;

    if (@tags) {
        # Create any tags that don't exist
        $stmt = database('link_creator')->prepare(
            'INSERT IGNORE INTO linkgarden_tags (name) VALUES ' . (join ",", (('(?)') x @tags))
        );
        $stmt->execute(@tags);
    }

    # Insert the actual post into the DB and get its ID
    $stmt = database('link_creator')->prepare(
        'INSERT INTO linkgarden (owner, name, url, description, icon, enable_comments) VALUES (?, ?, ?, ?, ?, ?)'
    );
    $stmt->execute($user->{id}, $name, $url, $description, $icon, $enable_comments);

    $stmt = database('link_creator')->prepare(
        'SELECT MAX(id) last_id FROM linkgarden'
    );
    $stmt->execute();
    my $entry_id = $stmt->fetchrow_hashref()->{last_id};

    # Ping mentioned users
    my @pinged = resolve_pings($description, 'post_ping', $name, "/entry/$entry_id");

    # Check if an image was attached
    if ($update_img) {
        # Save image URL
        $stmt = database('link_creator')->prepare(
            'UPDATE linkgarden SET image_url = ? WHERE id = ?'
        );
        $stmt->execute($img_url, $entry_id);
    }

    if (@tags) {
        # Now find all the tag IDs which will be associated with the post
        $stmt = database('link_creator')->prepare(
            'SELECT id FROM linkgarden_tags WHERE name IN (' . (join ",", (('?') x @tags))  . ')'
        );
        $stmt->execute(@tags);
        my $dbtags = $stmt->fetchall_arrayref({});

        # Now associate the tags with the post.
        my @assocs;
        for my $tag (@$dbtags) {
            push @assocs, $entry_id, $tag->{id};
        }
        $stmt = database('link_creator')->prepare(
            'INSERT INTO linkgarden_tag_assoc (link_id, tag_id) VALUES ' . join(', ', (('(?, ?)') x @tags))
        );
        $stmt->execute(@assocs);
    }

    redirect "/~$user->{name}/entry/$entry_id";
};

get '/~:user/entry/:id/edit/?' => require_login sub {
    my $username = route_parameters->get('user');
    my $link_id = route_parameters->get('id');

    my $link;
    eval {
        $link = get_link_by_id($link_id);
    }; if (my $error = $@) {
        status 'not_found';
        return template 'err', {
            error => $error,
        }
    }

    if (logged_in_user->{name} ne $link->{username}) {
        redirect_to_prev_view($link->{id}, query_parameters->get('page'));
    }

    $link->{tags} = join " ", @{$link->{tags}};

    my $post_type = "link";
    if ($link->{url} eq 'self') {
        $post_type = "text";
    }

    template 'post' => {
        common_template_params({
            user => $username,
        }),
        nav => [
            { name => "~$username", link => "/~$username" },
            { name => "all", link => "/~$username/all" },
            { name => $link->{name}, link => "/~$username/entry/$link->{id}" },
            { name => "edit", link => undef }
        ],
        back_page => query_parameters->get('page'),
        old_link => $link,
        link => $link,
        post_type => $post_type,
        title => "Edit entry &mdash; reallycoolwebsite.net",
        icons => [ @iconlist ],
        form_title => 'Edit entry',
        img_url => $link->{image_url},
    };
};

post '/~:user/entry/:id/edit/?' => require_login sub {
    my $username = route_parameters->get('user');
    my $link_id = route_parameters->get('id');

    if (body_parameters->get('cancel')) {
        return redirect_to_prev_view($link_id, body_parameters->get('back_page'));
    }

    my $old_link;
    eval {
        $old_link = get_link_by_id($link_id);
    }; if (my $error = $@) {
        status 'not_found';
        return template 'err', {
            error => $error,
        }
    }
    my $update_img;
    my $img_url;
    if (request->upload('image')) {
        say {\*STDERR} "Need to upload a new image!";
        $img_url = handle_upload(request->upload('image'));
    } elsif (body_parameters->get('remove_attachment')) {
        # Remove attached image
        $img_url = '';
    } elsif (body_parameters->get('cancel_image_remove')) {
        $img_url = $old_link->{image_url};
    } elsif (body_parameters->get('actually_existing_image')) {
        $img_url = body_parameters->get('actually_existing_image');
    }

    if (not body_parameters->get('save')) {
        # refreshing page, to preview or mess with attachment
        return preview(body_parameters, 'Edit entry', $old_link, $img_url, {});
    }

    # Okay, so we're saving the change
    my $user = logged_in_user;
    my $name = body_parameters->get('name');
    my @tags = split / /, body_parameters->get('tags');
    my $icon = body_parameters->get('icon');
    my $description = body_parameters->get('description');
    my $enable_comments = defined body_parameters->get('enable_comments') || 0;
    say "Comments enabled: $enable_comments";

    my $url;
    if (body_parameters->get('post_type') eq 'link') {
        $url = body_parameters->get('url');
        eval {
            die "Please provide a link!\n" unless $url;
            validate_link $url;
        }; if (my $error = $@) {
            return preview(body_parameters, 'New entry', undef, $img_url, {
                flash_icon => 'error',
                flash_msg => $error,
            });
        }
    } else {
        $url = 'self';
    }

    my $stmt;

    if (@tags) {
        # Filter out commas and hashtags
        @tags = map { s/[,#]//g; $_ } @tags;

        # Remove leading/trailing spaces
        @tags = map { s/^\s+|\s+$//g; $_ } @tags;

        # Remove empty tags
        @tags = grep { length $_ } @tags;

        # Create any tags that don't exist
        $stmt = database('link_creator')->prepare(
            'INSERT IGNORE INTO linkgarden_tags (name) VALUES ' . (join ",", (('(?)') x @tags))
        );
        $stmt->execute(@tags);
    }

    # Save edits
    $stmt = database('link_creator')->prepare(
        'UPDATE linkgarden SET name = ?, url = ?, description = ?, icon = ?, enable_comments = ? WHERE id = ?'
    );
    $stmt->execute($name, $url, $description, $icon, $enable_comments, $link_id);

    # Check if an image was attached
    if ($img_url ne $old_link->{image_url}) {
        # Save image URL
        $stmt = database('link_creator')->prepare(
            'UPDATE linkgarden SET image_url = ? WHERE id = ?'
        );
        $stmt->execute($img_url, $link_id);
    }

    # Remove old tag associations
    $stmt = database('link_creator')->prepare(
        'DELETE FROM linkgarden_tag_assoc WHERE link_id = ?'
    );
    $stmt->execute($link_id);

    if (@tags) {
        # Now find all the tag IDs which will be associated with the post
        $stmt = database('link_creator')->prepare(
            'SELECT id FROM linkgarden_tags WHERE name IN (' . (join ",", (('?') x @tags))  . ')'
        );
        $stmt->execute(@tags);
        my $dbtags = $stmt->fetchall_arrayref({});

        # Now associate the tags with the post.
        my @assocs;
        for my $tag (@$dbtags) {
            push @assocs, $link_id, $tag->{id};
        }
        $stmt = database('link_creator')->prepare(
            'INSERT INTO linkgarden_tag_assoc (link_id, tag_id) VALUES ' . join(', ', (('(?, ?)') x @tags))
        );
        $stmt->execute(@assocs);
    }

    redirect_to_prev_view($link_id, body_parameters->get('back_page'));
};

get '/~:user/entry/:id/delete/?' => require_login sub {
    my $username = route_parameters->get('user');
    my $link_id = route_parameters->get('id');

    my $link;
    eval {
        $link = get_link_by_id($link_id);
    }; if (my $error = $@) {
        status 'not_found';
        return template 'err', {
            error => $error,
        }
    }

    if (logged_in_user()->{name} ne $link->{username}) {
        return redirect_to_prev_view($link_id, query_parameters->get('page'));
    }

    template 'confirm_delete' => {
        common_template_params({
            user => $username,
        }),
        nav => [
            { name => "~$username", link => "/~$username" },
            { name => "all", link => "/~$username/all" },
            { name => $link->{name}, link => "/~$username/entry/$link->{id}" },
            { name => "delete", link => undef }
        ],
        link => $link,
        title => "Confirm delete &mdash; reallycoolwebsite.net",
        back_url => query_parameters->get('page'),
    };
};

post '/~:user/entry/:id/delete/?' => require_login sub {
    my $username = route_parameters->get('user');
    my $link_id = route_parameters->get('id');

    my $link;
    eval {
        $link = get_link_by_id($link_id);
    }; if (my $error = $@) {
        status 'not_found';
        return template 'err', {
            error => $error,
        }
    }

    if (logged_in_user()->{name} ne $link->{username}) {
        redirect '/';
    }

    database('link_creator')->quick_delete('linkgarden', { id => $link_id });

    redirect_to_prev_view(undef, query_parameters->get('path'));
};

1;
