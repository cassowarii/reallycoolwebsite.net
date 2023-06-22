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

    my $dbcomment = $stmt->fetchrow_hashref;
    if ($dbcomment) {
        return process_comment_from_db($dbcomment);
    } else {
        return {};
    }
}

# Short URL for a particular comment. Redirects to the post the comment is on
# and goes to the appropriate comment anchor
get '/comment/:id/?' => sub {
    my $comment_id = route_parameters->get('id');
    my $comment = get_comment($comment_id);

    if (not defined $comment) {
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
    my $post = get_link_by_id($post_id);

    leave_comment($post_id, $sticker, $comment_text);

    my $stmt = database('viewer')->prepare(
        "SELECT MAX(id) max_id FROM linkgarden_comments"
    );
    $stmt->execute();
    my $result = $stmt->fetchrow_hashref;
    my $new_comment_id = $result->{max_id};

    # Find pinged users and notify them
    my @pinged_ids;
    {
        my @pings = ( $comment_text =~ /@{[ USERNAME_REGEX ]}/g );
        say "pings: ", (join '; ', @pings);

        # Put in a hash to find unique pings
        my %pinged_users = ();
        @pinged_users{@pings} = @pings;

        # Remove initial ~'s from usernames
        my @pinged_users = map { s/^~//; $_ } keys %pinged_users;
        say "pinged_users: ", (join '; ', @pinged_users);

        if (@pinged_users) {
            # Find pinged users' IDs
            $stmt = database('viewer')->prepare(
                "SELECT id FROM linkgarden_users WHERE name IN (" . (join ",", (('?') x @pinged_users)) . ")"
            );
            $stmt->execute(@pinged_users);
            @pinged_ids = map { $_->{id} } @{$stmt->fetchall_arrayref({})};
            say "pinged ids: ", (join '; ', @pinged_ids);

            for my $ping_id (@pinged_ids) {
                notify_user(logged_in_user->{id}, $ping_id, 'ping', $post->{name}, "/comment/$new_comment_id") unless $ping_id == logged_in_user->{id};
            }
        }
    }

    # Notify about the comment unless we're commenting on our own post or were already pinged
    if ($post->{owner} != logged_in_user->{id} and not grep { $_ == $post->{owner} } @pinged_ids) {
        notify_user(logged_in_user->{id}, $post->{owner}, 'comment', $post->{name}, "/comment/$new_comment_id")
    }

    redirect "/~$user_id/entry/$post_id#comments-end";
};

get '/comment/:id/delete/?' => require_login sub {
    my $comment_id = route_parameters->get('id');

    my $comment = get_comment($comment_id);
    my $author = $comment->{author};
    my $post_id = $comment->{post};
    my $post = get_link_by_id($post_id);

    # We can delete our own comments, or comments on our own posts.
    my $can_delete = ($author == logged_in_user->{id} || $post->{owner} == logged_in_user->{id});
    return redirect "/comment/$comment_id" unless $can_delete;

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
    my $author = $comment->{author};
    my $post_id = $comment->{post};
    my $post = get_link_by_id($post_id);

    # We can delete our own comments, or comments on our own posts.
    my $can_delete = ($author == logged_in_user->{id} || $post->{owner} == logged_in_user->{id});
    return redirect "/comment/$comment_id" unless $can_delete;

    my $stmt;
    if ($post->{owner} eq logged_in_user->{id}) {
        # If it's a comment on our own post, nuke it entirely rather than marking it deleted
        $stmt = database('link_creator')->prepare(
            "DELETE FROM linkgarden_comments WHERE id = ?"
        );
    } else {
        # If it's a comment on a different post, leave the actual comment entry in the DB,
        # just mark it as "is deleted" (though we do actually delete the comment text)
        $stmt = database('link_creator')->prepare(
            "UPDATE linkgarden_comments SET author = 0, comment = '', is_deleted = 1 WHERE id = ?"
        );
    }
    $stmt->execute($comment_id);

    redirect "/entry/$post_id#comments";
};

post '/comment/:id/edit/?' => require_login sub {
    my $comment_id = route_parameters->get('id');

    my $new_text = body_parameters->get('comment');

    my $comment = get_comment($comment_id);
    my $author = $comment->{author};
    my $post_id = $comment->{post};

    # We can only edit our own comments.
    my $can_edit = $author == logged_in_user->{id};
    return redirect "/comment/$comment_id" unless $can_edit;

    my $stmt = database('link_creator')->prepare(
        "UPDATE linkgarden_comments SET comment = ? WHERE id = ?"
    );
    $stmt->execute($new_text, $comment_id);

    redirect "/comment/$comment_id";
}
