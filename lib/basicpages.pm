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

use constant PAGE_SIZE => 10;

get '/' => sub {
    if (logged_in_user) {
        my $stmt = database('viewer')->prepare(
            'SELECT * FROM linkgarden_follows WHERE follower = ?'
        );
        $stmt->execute(logged_in_user->{id});
        if ($stmt->fetchrow_hashref) {
            return redirect '/feed';
        }
    }

    template 'index' => {
        common_template_params({}),
        nav => [ ],
        title => 'reallycoolwebsite.net',
    };
};

get '/about/?' => require_login sub {
    template 'about' => {
        common_template_params({}),
        nav => [
            { name => 'about', link => '/about' }
        ],
        title => 'about &mdash; reallycoolwebsite.net',
    };
};

sub link_listing {
    my ($page, @dblinks) = @_;

    # Process links, but skip the last one because we are only using it to
    # check if we're on the last page or not.
    my $first_page = 0;
    my $last_page = 1;

    if ($page == 1) {
        $first_page = 1;
    }

    if (@dblinks > PAGE_SIZE) {
        # If we received an extra one, we know we're not on the last page.
        # But we don't want to display it, so remove it from the list.
        $last_page = 0;
        pop @dblinks;
    }

    my $links = [ map { process_link_from_db($_) } @dblinks ];

    return (
        first_page  => $first_page,
        last_page   => $last_page,
        links       => $links,
    );
}

sub link_page {
    my $username = shift;
    my $routepage = $_[0];

    my $page = $routepage // 1;
    my $page_offset = ($page - 1) * PAGE_SIZE;
    my $query_page_size = PAGE_SIZE + 1;

    my %ctparams = common_template_params({
        user => $username
    });

    my $stmt = entry_query('WHERE u.name = ?', 'ORDER BY l.created DESC LIMIT ?, ?');

    $stmt->execute($username, $page_offset, $query_page_size);

    # Raw link objects we got out of the DB.
    my @dblinks = @{$stmt->fetchall_arrayref({})};

    my $title;
    if (defined $routepage) {
        $title = "all (page $page) &mdash; $username\'s $ctparams{profile}{page_name}";
    } else {
        $title = "all &mdash; $username\'s $ctparams{profile}{page_name}";
    }

    my %link_stuff = link_listing($page, @dblinks);

    template 'all' => {
        %ctparams,
        nav => [
            { name => "~$username", link => "/~$username" },
            { name => 'all', link => undef }
        ],
        %link_stuff,
        title       => $title,
        pagenum     => $page,
        base_list_url => "/~$username/all",
    };
}

sub tag_page {
    my $username = shift;
    my $tagname = shift;
    my $routepage = $_[0];

    my $page = $routepage // 1;
    my $page_offset = ($page - 1) * PAGE_SIZE;
    my $query_page_size = PAGE_SIZE + 1;

    # Look up tag ID by name
    my $stmt = database('viewer')->prepare('SELECT * FROM linkgarden_tags WHERE name=?');
    $stmt->execute($tagname);
    my $taginfo = $stmt->fetchrow_hashref;
    my $tag_id = $taginfo->{id};

    # Get user-specific tag description
    $stmt = database('viewer')->prepare(
        'SELECT t.*, td.*, u.name username FROM linkgarden_tag_descs td
            INNER JOIN linkgarden_users u ON u.id = td.owner
            RIGHT JOIN linkgarden_tags t ON td.tag_id = t.id
            WHERE t.name = ? AND u.name = ?'
    );
    $stmt->execute($tagname, $username);
    my $tagdescrow = $stmt->fetchrow_hashref;

    my $tagdesc = undef;
    if ($tagdescrow) {
        $tagdesc = Encode::decode('utf8', $tagdescrow->{description});
        $tagdesc = format_text($tagdesc, $username);
    }

    my %ctparams = common_template_params({
        user => $username
    });

    $stmt = entry_query(
        'WHERE l.id IN (SELECT link_id FROM linkgarden_tag_assoc WHERE tag_id = ?) AND u.name = ?',
        'ORDER BY l.created DESC LIMIT ?, ?'
    );

    $stmt->execute($tag_id, $username, $page_offset, $query_page_size);

    # Raw link objects we got out of the DB.
    my @dblinks = @{$stmt->fetchall_arrayref({})};

    my $title;
    if (defined $routepage) {
        $title = "'$tagname' tag (page $page) &mdash; $username\'s $ctparams{profile}{page_name}";
    } else {
        $title = "'$tagname' tag &mdash; $username\'s $ctparams{profile}{page_name}";
    }

    my %link_stuff = link_listing($page, @dblinks);

    template 'tag' => {
        %ctparams,
        %link_stuff,
        nav => [
            { name => "~$username", link => "/~$username" },
            { name => 'tag', link => "/~$username/tag" }, { name => $tagname, link => undef }
        ],
        tagname     => $tagname,
        tagdesc     => $tagdesc,
        title       => $title,
        pagenum     => $page,
        base_list_url => "/~$username/tag/$tagname",
        tag_cloud => get_tag_cloud($username),
    };
}

sub generic_post_list {
    my %params = @_;

    my $routepage = $params{page};

    my $page = $routepage // 1;
    my $page_offset = ($page - 1) * PAGE_SIZE;
    my $query_page_size = PAGE_SIZE + 1;

    my %ctparams = common_template_params;

    my $stmt = entry_query($params{query1}, $params{query2});
    $stmt->execute(@{$params{query_params}}, $page_offset, $query_page_size);

    # Raw link objects we got out of the DB.
    my @dblinks = @{$stmt->fetchall_arrayref({})};

    my $title;
    if (defined $routepage) {
        $title = "$params{title} (page $page) &mdash; reallycoolwebsite.net";
    } else {
        $title = "$params{title} &mdash; reallycoolwebsite.net";
    }

    my %link_stuff = link_listing($page, @dblinks);

    template $params{template} => {
        %ctparams,
        nav => $params{nav},
        %link_stuff,
        title       => $title,
        pagenum     => $page,
        base_list_url => $params{base_list_url},
    };
}

sub feed_page {
    my $routepage = shift;

    generic_post_list(
        page => $routepage,
        title => 'feed',
        template => 'feed',
        nav => [
            { name => "feed", link => undef }
        ],
        base_list_url => "/feed",
        query1 => 'INNER JOIN linkgarden_follows AS f ON (f.followee = u.id AND f.follower = ?)',
        query2 => 'ORDER BY l.created DESC LIMIT ?, ?',
        query_params => [ logged_in_user->{id} ],
    );
}

sub bookmark_page {
    my $routepage = shift;

    generic_post_list(
        page => $routepage,
        title => 'bookmarks',
        template => 'bookmarks',
        nav => [
            { name => "bookmarks", link => undef }
        ],
        base_list_url => "/bookmarks",
        query1 => 'INNER JOIN linkgarden_bookmarks AS bkm ON (bkm.liker = ? AND bkm.post_id = l.id)',
        query2 => 'ORDER BY l.created DESC LIMIT ?, ?',
        query_params => [ logged_in_user->{id} ],
    );
}

get '/~:user/tag/?' => sub {
    my $username = route_parameters->get('user');

    my %ctparams = common_template_params({
        user => $username
    });

    template 'tag_cloud_landing' => {
        %ctparams,
        nav => [
            { name => "~$username", link => "/~$username" },
            { name => 'tag', link => undef },
        ],
        title => "tags &mdash; $username\'s $ctparams{profile}{page_name}",
        tag_cloud => get_tag_cloud($username),
    };
};

get '/~:user/tag/:tagname/?' => sub {
    tag_page(route_parameters->get('user'), route_parameters->get('tagname'));
};

get '/~:user/tag/:tagname/page/:pagenum/?' => sub {
    tag_page(route_parameters->get('user'), route_parameters->get('tagname'), route_parameters->get('pagenum'));
};

get '/~:user/all/?' => sub {
    link_page(route_parameters->get('user'));
};

get '/~:user/all/page/:pagenum/?' => sub {
    link_page(route_parameters->get('user'), route_parameters->get('pagenum'));
};

get '/feed/?' => require_login sub {
    feed_page();
};

get '/feed/page/:pagenum/?' => require_login sub {
    feed_page(route_parameters->get('pagenum'));
};

get '/bookmarks' => require_login sub {
    say "BOOKMARK PAGE";
    bookmark_page();
};

get '/bookmarks/page/:pagenum' => require_login sub {
    bookmark_page(route_parameters->get('pagenum'));
};

get '/entry/:id/?' => sub {
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

    redirect "/~$username/entry/$link_id";
};

get '/~:user/entry/:id/?' => sub {
    my $username = route_parameters->get('user');
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

    # If username in URL wrong, redirect to correct author
    if ($link->{username} ne $username) {
        return redirect "/~$link->{username}/entry/$link_id";
    }

    # Get previous and next posts
    my ($prev_id, $next_id, $prev_title, $next_title);

    # prev
    my $stmt = database('viewer')->prepare(
        'SELECT l.id link_id, l.name name FROM linkgarden l
            INNER JOIN linkgarden_users u ON l.owner = u.id
            WHERE u.name = ? AND l.id < ?
            ORDER BY l.created DESC LIMIT 1'
    );
    $stmt->execute($username, $link_id);
    my $result = $stmt->fetchrow_hashref;
    if ($result) {
        $prev_id = $result->{link_id};
        $prev_title = Encode::decode('utf8', $result->{name});
    }
    # next
    $stmt = database('viewer')->prepare(
        'SELECT l.id link_id, l.name name FROM linkgarden l
            INNER JOIN linkgarden_users u ON l.owner = u.id
            WHERE u.name = ? AND l.id > ?
            ORDER BY l.created ASC LIMIT 1'
    );
    $stmt->execute($username, $link_id);
    $result = $stmt->fetchrow_hashref;
    if ($result) {
        $next_id = $result->{link_id};
        $next_title = Encode::decode('utf8', $result->{name});
    }

    # Retrieve comments
    $stmt = database('viewer')->prepare(
        'SELECT cmt.*, u.name username FROM linkgarden_comments cmt
            INNER JOIN linkgarden_users u ON cmt.author = u.id
            WHERE cmt.post = ?
            ORDER BY cmt.created ASC'
    );
    $stmt->execute($link_id);
    my $comments = $stmt->fetchall_arrayref({});

    my %ctparams = common_template_params({
        user => $username
    });

    template 'single_post' => {
        %ctparams,
        nav => [
            { name => "~$username", link => "/~$username" },
            { name => "all", link => "/~$username/all" },
            { name => $link->{name}, link => undef },
        ],
        title => "$link->{name} &mdash; $username\'s $ctparams{profile}{page_name}",
        link  => $link,
        prev_id => $prev_id,
        next_id => $next_id,
        prev_title => $prev_title,
        next_title => $next_title,
        comments => $comments,
    };
};

get '/~:user/search/?' => sub {
    my $username = route_parameters->get('user');
    my $query = query_parameters->get('q');

    my %ctparams = common_template_params({
        user => $username
    });

    my $results = ();
    if ($query) {
        my $stmt = entry_query(
            'WHERE (l.name LIKE ? OR l.description LIKE ? OR l.url LIKE ?) AND u.name = ?',
            'ORDER BY l.created DESC'
        );

        $stmt->execute("%$query%", "%$query%", "%$query%", $username);

        my $results = $stmt->fetchall_arrayref({});
        $results = [ map { process_link_from_db($_) } @$results ];

        template 'search_page' => {
            %ctparams,
            nav => [
                { name => "~$username", link => "/~$username" },
                { name => "search", link => undef },
            ],
            title => "search $username\'s $ctparams{profile}{page_name}",
            query => $query,
            links => $results,
        };
    } else {
        template 'search_page' => {
            %ctparams,
            nav => [
                { name => "~$username", link => "/~$username" },
                { name => "search", link => undef },
            ],
            title => "search $username\'s $ctparams{profile}{page_name}",
        };
    }
};

get '/~:user/random/?' => sub {
    my $username = route_parameters->get('user');

    my %ctparams = common_template_params({
        user => $username
    });

    my $stmt = database('viewer')->prepare(
        "SELECT l.id random_id
            FROM linkgarden AS l
            INNER JOIN linkgarden_users AS u ON l.owner = u.id
            WHERE u.name = ?
            ORDER BY RAND() LIMIT 1"
    );
    $stmt->execute($username);

    my $result = $stmt->fetchrow_hashref;

    if (!$result) {
        redirect "/~$username/all";
    }

    my $random_id = $result->{random_id};

    redirect "/~$username/entry/$random_id";
};

get '/recent/?' => sub {
    my $stmt = database('viewer')->prepare(
        'SELECT u.name, u.page_name, MAX(l.created) last_post
            FROM linkgarden_users u
            INNER JOIN linkgarden AS l ON l.owner = u.id
            GROUP BY u.id
            ORDER BY last_post DESC
            LIMIT 25'
    );
    $stmt->execute();
    my $recents = $stmt->fetchall_arrayref({});

    template 'recent_posts', {
        common_template_params,
        nav => [
            { name => "recent", link => undef }
        ],
        recents => $recents,
    }
};
