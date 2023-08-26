package linkgarden;
use strict;
use warnings;
use utf8;

use v5.16;

use Dancer2 appname => 'linkgarden';
use Dancer2::Plugin::Database;
use Dancer2::Plugin::Auth::Extensible;

use Dancer2::Core::Error;

use Encode;
use Parse::BBCode;
use HTML::Escape qw( escape_html );

use List::Util qw( max min );

use constant USERNAME_REGEX => qr{(?<![a-z0-9_\./:\#])([@~])([a-z](?:[a-z0-9_\.-]*[a-z0-9])?)}i;

my $bbcode_parser = Parse::BBCode->new({
    url_finder => {
        max_length => 0,
        format => '<a href="%s" target="_blank" rel="nofollow">%s</a>',
    },
    tags => {
        Parse::BBCode::HTML->defaults,
        tt => '<tt>%s</tt>',
        code => '<tt>%s</tt>',
        quote => 'block:<blockquote>%s</blockquote>',
        s => '<s>%s</s>',
    },
});

sub random_color() {
    my @colors = qw( red orange yellow green blue purple );
    return $colors[rand @colors];
}

sub notify_user {
    my ($from_user, $to_user, $type, $msg, $link) = @_;

    database('link_creator')->quick_insert('linkgarden_notifications',
        {
            from_user => $from_user,
            to_user => $to_user,
            type => $type,
            msg => $msg,
            link => $link,
        });
}

sub has_unread_notifications {
    my ($user_id) = @_;

    my $stmt = database('viewer')->prepare(
        "SELECT COUNT(*) total FROM linkgarden_notifications WHERE to_user = ? AND unread = 1"
    );
    $stmt->execute($user_id);
    my $result = $stmt->fetchrow_hashref;

    return ($result->{total} > 0);
}

sub common_template_params {
    my ($params) = @_;

    my $profilename = $params->{user};

    my $profile = undef;
    if ($profilename) {
        my $stmt = database('viewer')->prepare(
            "SELECT *
                FROM linkgarden_users
                WHERE name = ?"
        );
        $stmt->execute($profilename);
        my $dbuser = $stmt->fetchrow_hashref;
        if (!$dbuser) {
            status 'not_found';
            return (
                is_ctparam_error => 1,
                error => "There is no user named $profilename. Please check the spelling and try again.",
                color => 'blank',
            );
        }
        $profile = process_user_from_db($dbuser);
    }

    my $user = undef;
    if (logged_in_user) {
        $user = process_user_from_db(logged_in_user);
    }

    my $notification = undef;
    if (logged_in_user) {
        $notification = has_unread_notifications(logged_in_user->{id}),
    }

    return (
        user => $user,
        profile => $profile,
        color => $params->{color} // random_color,
        unread_notifications => $notification,
    );
}

# Redirect back to a previous page and scroll to the anchor of a post.
sub redirect_to_prev_view {
    my ($link_id, $prev_page) = @_;

    if ($link_id) {
        if ($prev_page) {
            # Redirect back to where we were and scroll to named anchor of the post we were doing
            return redirect $prev_page . "#entry-id-$link_id";
        } else {
            # If we lost track of where we were ( :( ) then just go to our link's page
            return redirect "/entry/$link_id";
        }
    } else {
        if ($prev_page) {
            # Redirect back to where we were but we probably deleted the post or something
            return redirect $prev_page;
        } else {
            # If we somehow lost track of where we were AND what we were doing just go back to our all page
            return redirect "/~" . logged_in_user->{name} . '/all';
        }
    }
}

# Process a user that we've just pulled out of the database.
sub process_user_from_db {
    my %user = %{$_[0]};

    $user{short_desc} = Encode::decode('utf8', $user{short_desc});
    $user{long_desc} = Encode::decode('utf8', $user{long_desc});
    $user{formatted_short_desc} = format_text($user{short_desc}, $user{name});
    $user{formatted_long_desc} = format_text($user{long_desc}, $user{name});

    return \%user;
}

# SQL INJECTION RISK! DO NOT PASS USER DATA INTO THIS FUNCTION
sub entry_query {
    my ($where, $extra) = @_;

    my $bkquery1 = '';
    my $bkquery2 = '';
    if (logged_in_user) {
        my $user_id = logged_in_user->{id};
        $bkquery1 = ", COUNT(DISTINCT bk.liker) bookmark";
        $bkquery2 = "LEFT  JOIN linkgarden_bookmarks AS bk ON (bk.post_id = l.id AND bk.liker = $user_id)";
    }

    # TODO: need to figure out how to make this query not terrible
    my $query = <<QUERY

        SELECT l.*,
                GROUP_CONCAT(DISTINCT t.name SEPARATOR ' ') tags,
                u.name username,
                GROUP_CONCAT(DISTINCT lku.name SEPARATOR ' ') likers,
                (SELECT COUNT(*) FROM linkgarden_comments cmt WHERE l.id = cmt.post AND cmt.is_deleted = 0) num_comments
                $bkquery1
            FROM linkgarden as l
            LEFT  JOIN linkgarden_likes AS lk ON lk.post_id = l.id
            LEFT  JOIN linkgarden_users AS lku ON lk.liker = lku.id
            LEFT  JOIN linkgarden_tag_assoc AS a ON a.link_id = l.id
            LEFT  JOIN linkgarden_tags AS t ON a.tag_id = t.id
            $bkquery2
            INNER JOIN linkgarden_users AS u ON u.id = l.owner
            $where
            GROUP BY l.id

QUERY
    ;

    $query .= $extra if $extra;

    print "Constructed query: $query";

    return database('viewer')->prepare($query);
}

sub get_link_by_id {
    my ($link_id) = @_;

    return {} if not $link_id;

    my $stmt = entry_query("WHERE l.id = ?");

    $stmt->execute($link_id);

    my $result = $stmt->fetchrow_hashref;

    if (!$result) {
        die "There is no entry with ID $link_id!\n";
    }

    my $link = process_link_from_db($result);

    return $link;
}

sub format_single_tag {
    my ($tag) = @_;

    $tag = Encode::decode('utf8', $tag);
    $tag = lc $tag;
    $tag =~ s/^#//g;
    $tag =~ s/[<>]//g;
    return $tag;
}

sub fix_tags($) {
    my ($tag_str) = @_;

    # Split by spaces/commas and remove any opening hashtags;
    # remove <> as a simple fix against injection;
    # also remove empty tags and sort alphabetically
    return sort { $a cmp $b }
           grep { length > 0 }
           map { format_single_tag($_) }
           split /[ ,]/, $tag_str;
}

# Process a link that we've just pulled out of the database.
sub process_link_from_db {
    my %link = %{$_[0]};

    # Split tags up by spaces, convert charset, strip any commas from them, and sort them alphabetically.
    $link{tags} = [ fix_tags $link{tags} ];

    # If link is to a Youtube video, add a key for that.
    if ($link{url} =~ m{^https?://(www\.)?youtube\.com/watch\?v=.+$}) {
        $link{url} =~ m{v=([^&]+)};
        $link{youtube} = $1;
    } elsif ($link{url} =~ m{^https?://(www\.)?youtu\.be/.+$}) {
        $link{url} =~ m{youtu\.be/([^&/=]+)$};
        $link{youtube} = $1;
    }

    $link{name} = Encode::decode('utf8', $link{name});
    $link{description} = Encode::decode('utf8', $link{description});

    $link{formatted_description} = format_text($link{description}, $link{username});

    $link{created_day} = substr $link{created}, 0, 10;

    $link{hearted} = 0;
    if ($link{likers}) {
        $link{likers} = [ split / /, $link{likers} ];
    } else {
        $link{likers} = [ ];
    }
    $link{nhearts} = scalar @{$link{likers}};
    # If *we* are among the list of people who liked it, mark... that we liked it
    if (logged_in_user and grep { $_ eq logged_in_user->{name} } @{$link{likers}}) {
        $link{hearted} = 1;
    }

    return \%link;
};

sub process_comment_from_db {
    my %comment = %{$_[0]};

    $comment{comment} = Encode::decode('utf8', $comment{comment});
    $comment{formatted_comment} = format_text($comment{comment}, $comment{username});

    return \%comment;
}

sub format_text {
    my ($txt, $username) = @_;

    # Process input text as bbcode
    $txt = $bbcode_parser->render($txt);

    # Convert ~usernames to links.
    $txt =~ s{@{[ USERNAME_REGEX ]}}{<a href="/~@{[ lc $2 ]}/">$1$2</a>}gi;

    # Convert #tag-names to links.
    $txt =~ s{(?<=[^a-zA-Z0-9_./:#-])#([a-zA-Z]([a-zA-Z0-9'_.-]*[a-z0-9])?)}{<a href="/~$username/tag/@{[ lc $1 ]}">#$1</a>}gi;

    return $txt;
}

# Perform a query to get a list of tags with tag cloud info attached.
sub get_tag_cloud {
    my ($username) = @_;

    my $stmt = database('viewer')->prepare(
        'SELECT t.*, COUNT(a.link_id) tag_count FROM linkgarden_tags t
            INNER JOIN linkgarden_tag_assoc AS a ON (a.tag_id = t.id)
            INNER JOIN linkgarden AS l ON (a.link_id = l.id)
            INNER JOIN linkgarden_users AS u ON (l.owner = u.id)
            WHERE u.name = ?
            GROUP BY t.id
            ORDER BY t.name ASC'
    );

    $stmt->execute($username);

    my @tags = @{$stmt->fetchall_arrayref({})};

    my $min_font_size = 13;
    my $max_font_size = 33;

    for my $tag (@tags) {
        # Make sure no funny business going on here (and decode unicode importantly)
        $tag->{name} = format_single_tag($tag->{name});

        # Wacky Perl rounding with sprintf.
        # To get the size of a tag in the tag cloud,
        # we take the square root, multiply it by nine,
        # round to the nearest integer, then add 4.
        # This gives a good distribution of sizes.
        $tag->{size} = (sprintf "%.0f", (sqrt($tag->{tag_count}) * 9)) + 4;
    }

    # If largest tag is bigger than the max size, scale
    # down the rest of the tags proportionally so that
    # the largest tag ends up being $max_font_size.
    # But we keep the smallest tag at the minimum size
    # as well, we just scale down the proportions between
    # those two sizes.
    my $biggest_tag = max map { $_->{size} } @tags;
    if ($biggest_tag > $max_font_size) {
        for my $t (@tags) {
            $t->{size} = ($t->{size} - $min_font_size)
                / ($biggest_tag - $min_font_size)
                * ($max_font_size - $min_font_size)
                + $min_font_size;
        }
    }

    return {
        line_height => min($biggest_tag, $max_font_size),
        ntags => scalar @tags,
        tags => \@tags,
    };
}

# Check link makes sense
sub validate_link($) {
    my ($link) = @_;

    # https://daringfireball.net/2010/07/improved_regex_for_matching_urls
    if ($link !~ m{
        ^
          (?:
            [a-z][\w-]+:                # URL protocol and colon
            (?:
              /{1,3}                        # 1-3 slashes
              |                             #   or
              [a-z0-9%]                     # Single letter or digit or '%'
                                            # (Trying not to match e.g. "URI::Escape")
            )
            |                           #   or
            www\d{0,3}[.]               # "www.", "www1.", "www2." … "www999."
            |                           #   or
            [a-z0-9.\-]+[.][a-z]{2,4}/  # looks like domain name followed by a slash
          )
          (?:                           # One or more:
            [^\s()<>]+                      # Run of non-space, non-()<>
            |                               #   or
            \(([^\s()<>]+|(\([^\s()<>]+\)))*\)  # balanced parens, up to 2 levels
          )+
          (?:                           # End with:
            \(([^\s()<>]+|(\([^\s()<>]+\)))*\)  # balanced parens, up to 2 levels
            |                                   #   or
            [^\s`!()\[\]{};:'".,<>?«»“”‘’]        # not a space or one of these punct chars
          )
        $
    }xi) {
        die "Link is not formatted correctly\n";
    }

    if ($link !~ /https?:\/\//) {
        die "HTTP links only for now, sorry!\n";
    }

    if (length $link > 150) {
        die "Dude that link is way too long\n";
    }

    return;
}

# Ensure password meets minimum requirements
sub validate_password($) {
    my ($password) = @_;

    if (length $password < 8) {
        die "Password is too short! (must be at least 8 characters)\n";
    }

    return;
}

# Ensure email looks good
sub validate_email($) {
    my ($email) = @_;

    if ($email !~ /^[a-z0-9._-]+(\+[a-z0-9._-])?@[a-z0-9._-]+\.[a-z]+$/i) {
        die "Please provide a valid email address!\n";
    }

    return;
}

true;
