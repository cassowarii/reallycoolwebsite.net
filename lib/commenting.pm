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

# CRUD, baybee

sub leave_comment {
    my ($post_id, $sticker, $comment_text) = @_;

    my $stmt = database('link_creator')->prepare(
        "INSERT INTO linkgarden_comments (post, author, sticker, comment) VALUES (?, ?, ?, ?)"
    );
    $stmt->execute($post_id, logged_in_user->{id}, $sticker, $comment_text);
}

sub get_comment {
    my ($comment_id) = @_;

    my $stmt = database('viewer')->prepare(
        "SELECT cmt.*, u.name username
            FROM linkgarden_comments cmt
            INNER JOIN linkgarden_users u ON cmt.author = u.id
            WHERE cmt.id = ?"
    );
    $stmt->execute($comment_id);

    return $stmt->fetchrow_hashref;
}

sub edit_comment {
    # TODO
}

get '/comment/:id/?' => sub {
    my $comment_id = route_parameters->get('id');
    my $comment = get_comment($comment_id);

    if (not defined $comment) {
        say "got here!";
        status 'not_found';
        return template 'err', {
            error => "No comment with ID $comment_id found. It may have been deleted."
        };
    }

    my $post_id = $comment->{post};
    my $post = get_link_by_id($post_id);

    return redirect "/~$post->{username}/entry/$post_id#comment-id-$comment_id";
};

post '/~:user/entry/:id/leave-comment/?' => require_login sub {
    my $user_id = route_parameters->get('user');
    my $post_id = route_parameters->get('id');
    my $sticker = body_parameters->get('sticker');
    my $comment_text = body_parameters->get('comment');

    leave_comment($post_id, $sticker, $comment_text);

    redirect "/~$user_id/entry/$post_id#comments-end";
};

get '/comment/:id/delete/?' => require_login sub {
    my $comment_id = route_parameters->get('id');

    my $comment = get_comment($comment_id);
    my $author = $comment->{author};
    my $post_id = $comment->{post};
    my $post = get_link_by_id($post_id);

    # Make sure we are actually, um, trying to delete our own comment lol -
    # if not just redirect back to page
    return redirect "/~$post->{username}/entry/$post_id#comment-id-$comment_id" unless $author eq logged_in_user->{id};

    template 'confirm_delete_comment' => {
        common_template_params({
            user => $post->{username},
        }),
        nav => [
            { name => "~$post->{username}", link => "/~$post->{username}" },
            { name => "all", link => "/~$post->{username}/all" },
            { name => $post->{name}, link => "/~$post->{username}/entry/$post->{id}" },
            { name => "comment", link => "/~$post->{username}/entry/$post->{id}#comment-id-$comment_id" },
            { name => "delete", link => undef }
        ],
        comment => $comment,
        title => "Confirm delete comment &mdash; reallycoolwebsite.net",
        back_url => query_parameters->get('page'),
    };
};

post '/comment/:id/delete/?' => require_login sub {
    my $comment_id = route_parameters->get('id');

    my $comment = get_comment($comment_id);
    my $post_id = $comment->{post};
    my $author = $comment->{author};

    # Redirect back if we are trying to delete someone else's comment
    return redirect "/entry/$post_id#comment-id-$comment_id" unless $author eq logged_in_user->{id};

    database('link_creator')->quick_delete('linkgarden_comments', { id => $comment_id });

    redirect "/entry/$post_id#comments";
};
