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

# CRUD

#C
sub leave_comment {
    my ($post_id, $sticker, $comment_text) = @_;

    my $stmt = database('link_creator')->prepare(
        "INSERT INTO linkgarden_comments (post, author, sticker, comment) VALUES (?, ?, ?, ?)"
    );
    $stmt->execute($post_id, logged_in_user->{id}, $sticker, $comment_text);
}

#R
sub get_comment {
    my ($comment_id) = @_;

    my $stmt = database('viewer')->prepare(
        "SELECT * FROM linkgarden_comments WHERE id = ?"
    );
    $stmt->execute($comment_id);

    return $stmt->fetchrow_hashref;
}

#U
sub edit_comment {
    # TODO
}

#D
sub delete_comment {
    my ($comment_id) = @_;

    my $stmt = database('link_creator')->prepare(
        "DELETE FROM linkgarden_comments WHERE id = ?"
    );
    $stmt->execute($comment_id);
}

post '/~:user/entry/:id/leave-comment' => require_login sub {
    my $user_id = route_parameters->get('user');
    my $post_id = route_parameters->get('id');
    my $sticker = body_parameters->get('sticker');
    my $comment_text = body_parameters->get('comment');

    leave_comment($post_id, $sticker, $comment_text);

    redirect "/~$user_id/entry/$post_id";
};

post '/comment/:id/delete' => require_login sub {
    my $comment_id = route_parameters->get('id');

    my $post_id = get_comment($comment_id)->{post};

    delete_comment($comment_id);

    redirect "/entry/$post_id";
};
