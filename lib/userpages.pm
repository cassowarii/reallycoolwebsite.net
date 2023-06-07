package linkgarden;
use strict;
use warnings;
use utf8;

use v5.16;

use Dancer2 appname => 'linkgarden';
use Dancer2::Plugin::Database;

use Encode;
use Parse::BBCode;

use util;

sub login_page_handler {
    my $return_url = query_parameters->get('return_url');
    template 'login', {
        title => 'Log in',
        return_url => $return_url,
    }, {
        layout => 'login.tt',
    };
}

get '/~:user/?' => sub {
    my $username = route_parameters->get('user');

    my %ctparams = common_template_params({
        user => $username
    });

    my $following = 0;
    if (!$ctparams{is_error}) {
        # If we're logged in and sure this is a real user...
        if (logged_in_user) {
            # check if we follow them
            my $stmt = database('viewer')->prepare(
                'SELECT * FROM linkgarden_follows WHERE followee = ? AND follower = ?'
            );
            $stmt->execute($ctparams{profile}{id}, logged_in_user->{id});
            if ($stmt->fetchrow_hashref) {
                $following = 1;
            }
        }
    }

    template 'user_page' => {
        %ctparams,
        nav => [
            { name => "~$username", link => undef }
        ],
        title => "$username\'s $ctparams{profile}{page_name}",
        following => $following,
        tag_cloud => get_tag_cloud($username),
    };
};

get '/~:user/follow/?' => require_login sub {
    my $username = route_parameters->get('user');

    my $stmt;

    # Get ID of user to follow
    $stmt = database('viewer')->prepare(
        "SELECT * FROM linkgarden_users WHERE name = ?"
    );
    $stmt->execute($username);
    my $result = $stmt->fetchrow_hashref;
    if (!$result) {
        return template 'err', {
            error => "No user named $username, cannot follow them!",
        }
    }
    my $follow_id = $result->{id};

    # INSERT IGNORE so that double-follows don't cause errors (cf hearts)
    $stmt = database('link_creator')->prepare(
        "INSERT IGNORE INTO linkgarden_follows (follower, followee) VALUES (?, ?)"
    );
    $stmt->execute(logged_in_user->{id}, $follow_id);

    redirect "/~$username";
};

get '/~:user/unfollow/?' => require_login sub {
    my $username = route_parameters->get('user');

    my $stmt;

    # Get ID of user to unfollow
    $stmt = database('viewer')->prepare(
        "SELECT * FROM linkgarden_users WHERE name = ?"
    );
    $stmt->execute($username);
    my $result = $stmt->fetchrow_hashref;
    if (!$result) {
        return template 'err', {
            error => "No user named $username, cannot follow them!",
        }
    }
    my $follow_id = $result->{id};

    $stmt = database('link_creator')->prepare(
        "DELETE FROM linkgarden_follows WHERE follower = ? AND followee = ?"
    );
    $stmt->execute(logged_in_user->{id}, $follow_id);

    redirect "/~$username";
};

get '/~:user/about/?' => sub {
    my $username = route_parameters->get('user');

    my %ctparams = common_template_params({
        user => $username
    });

    my $stmt = database('viewer')->prepare(
        "SELECT COUNT(*) total_number
            FROM linkgarden AS l
            INNER JOIN linkgarden_users AS u ON l.owner = u.id
            WHERE u.name = ?"
    );
    $stmt->execute($username);
    my $num_posts = $stmt->fetchrow_hashref->{total_number};

    my $num_tags = scalar @{get_tag_cloud($username)->{tags}};

    template 'user_about_page' => {
        %ctparams,
        nav => [
            { name => "~$username", link => "/~$username" },
            { name => "about", link => undef },
        ],
        title => "About $username\'s $ctparams{profile}{page_name}",
        num_posts => $num_posts,
        num_tags => $num_tags,
    };
};

get '/user-menu' => require_login sub {
    my $from_page = query_parameters->get('page');

    template 'user_menu' => {
        common_template_params({}),
        title => "User menu",
        from_page => $from_page,
    };
};

get '/update-profile' => require_login sub {
    template 'update_profile' => {
        common_template_params({}),
        nav => [
            { name => "update profile", link => undef }
        ],
        title => "User menu",
    };
};

post '/update-profile' => require_login sub {
    my $short_desc = body_parameters->get('short_desc');
    my $long_desc = body_parameters->get('long_desc');
    my $page_name = body_parameters->get('page_name');
    my $user = logged_in_user;

    update_current_user short_desc => $short_desc, long_desc => $long_desc, page_name => $page_name;

    redirect "/~" . logged_in_user->{name};
};

1;
