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

get '/entry/:id/heart' => require_login sub {
    my $link_id = route_parameters->get('id');

    my $link;
    eval {
        $link = get_link_by_id($link_id);
    }; if (my $error = $@) {
        status 'not_found';
        return template 'err', {
            error => $error,
        };
    }

    my $username = $link->{username};

    # Redirect to the version with the username
    redirect "/~$username/entry/$link_id/heart?" . request->query_string;
};

get '/entry/:id/unheart' => require_login sub {
    my $link_id = route_parameters->get('id');

    my $link;
    eval {
        $link = get_link_by_id($link_id);
    }; if (my $error = $@) {
        status 'not_found';
        return template 'err', {
            error => $error,
        };
    }

    my $username = $link->{username};

    # Redirect to the version with the username
    redirect "/~$username/entry/$link_id/unheart?" . request->query_string;
};

get '/~:user/entry/:id/heart' => require_login sub {
    my $profile_name = route_parameters->get('user');
    my $link_id = route_parameters->get('id');

    associate_user_with_post('linkgarden_likes', $link_id);

    return redirect_to_prev_view($link_id, query_parameters->get('page'));
};

get '/~:user/entry/:id/bookmark' => require_login sub {
    my $profile_name = route_parameters->get('user');
    my $link_id = route_parameters->get('id');

    associate_user_with_post('linkgarden_bookmarks', $link_id);

    return redirect_to_prev_view($link_id, query_parameters->get('page'));
};

get '/~:user/entry/:id/unheart' => require_login sub {
    my $profile_name = route_parameters->get('user');
    my $link_id = route_parameters->get('id');

    disassociate_user_from_post('linkgarden_likes', $link_id);

    return redirect_to_prev_view($link_id, query_parameters->get('page'));
};

get '/~:user/entry/:id/unbookmark' => require_login sub {
    my $profile_name = route_parameters->get('user');
    my $link_id = route_parameters->get('id');

    disassociate_user_from_post('linkgarden_bookmarks', $link_id);

    return redirect_to_prev_view($link_id, query_parameters->get('page'));
};

sub associate_user_with_post {
    my ($table, $link_id) = @_;

    # INSERT IGNORE so that double-likes don't cause errors
    my $stmt = database('link_creator')->prepare(
        "INSERT IGNORE INTO $table (liker, post_id) VALUES (?, ?)"
    );
    $stmt->execute(logged_in_user->{id}, $link_id);
}

sub disassociate_user_from_post {
    my ($table, $link_id) = @_;

    # delete like from database
    my $stmt = database('link_creator')->prepare(
        "DELETE FROM $table WHERE liker = ? AND post_id = ?"
    );
    $stmt->execute(logged_in_user->{id}, $link_id);
}

1;
