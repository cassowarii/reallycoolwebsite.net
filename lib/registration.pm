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

my @forbidden_usernames = (
    'admin', 'administrator', 'reallycoolwebsite',
    'rcw', 'reallycoolwebsite.net', 'moderator',
    'cass0wary', 'rcw.net'
);

get '/register/?' => sub {
    redirect '/' if logged_in_user;

    my $math1 = sprintf "%d", rand 10;
    my $math2 = sprintf "%d", rand 10;

    template 'register', {
        common_template_params,
        color => 'blank',
        nav => [
            { name => 'register', link => undef },
        ],
        hide_login_button => 1,
        math1 => $math1,
        math2 => $math2,
    }
};

post '/register/?' => sub {
    redirect '/' if logged_in_user;

    # Do something lol
    my $math = body_parameters->get('math');
    my $math1 = body_parameters->get('math1');
    my $math2 = body_parameters->get('math2');
    my $username = body_parameters->get('username');
    my $password = body_parameters->get('password');
    my $confirm_password = body_parameters->get('confirm_password');
    my $email = body_parameters->get('email');

    my $err_msg;

    if ($username !~ /^[a-z0-9._-]+$/i) {
        $err_msg = 'Usernames can only contain letters, numbers, dashes, underscores, or dots.';
    }

    if ($username !~ /^[a-z]/i) {
        $err_msg = 'Username must start with a letter.';
    }

    if ($username !~ /^[a-z0-9]/i) {
        $err_msg = 'Username must end with a letter or a number.';
    }

    $username = lc $username;

    if (grep { $_ eq $username } @forbidden_usernames) {
        $err_msg = 'Sorry, that username is forbidden. Please choose a different one.';
    }

    # Check if username already taken
    if (!$err_msg) {
        my $stmt = database('viewer')->prepare(
            'SELECT * FROM linkgarden_users WHERE name = ?'
        );
        $stmt->execute($username);

        my $preexisting_user = $stmt->fetchrow_hashref;

        if ($preexisting_user) {
            $err_msg = 'Requested username is already in use. Please choose a different one.',
        }
    }

    # Check if passwords match
    if (!$err_msg) {
        if ($password ne $confirm_password) {
            $err_msg = 'Sorry, the passwords you entered do not match.',
        }
    }

    # Anti-spam
    if (!$err_msg) {
        if (!$math) {
            $err_msg = 'Please provide an answer to the math question!',
        } else {
            my $did_math = 0;

            if ($math =~ /^(\d+)\s*earth$/i) {
                if ($math1 + $math2 == $1) {
                    $did_math = 1;
                }
            }

            if (!$did_math) {
                $err_msg = 'Your math question answer is incorrect :(',
            }
        }
    }

    if ($err_msg) {
        return template 'register', {
            common_template_params,
            color => 'blank',
            nav => [
                { name => 'register', link => undef },
            ],
            hide_login_button => 1,
            flash_icon => 'error',
            flash_msg => $err_msg,
            math => $math,
            math1 => $math1,
            math2 => $math2,
            username => $username,
            email => $email,
        }
    }

    # Now we can create the user :)
    create_user username => $username, email => $email, email_welcome => 0;
    user_password username => $username, new_password => $password;

    template 'register_success', {
        common_template_params,
        color => 'blank',
        nav => [
            { name => 'registered!', link => undef },
        ],
    }
};

sub welcome_email_text {
    my ($dsl, %params) = @_;
    my $user_email = $params{email};
    my $reset_code = $params{code};
    # Send email
    # return $result;
    return "hello!";
}

get '/user-list/?' => require_role admin => sub {
    my $stmt = database('viewer')->prepare(
        'SELECT * FROM linkgarden_users ORDER BY created DESC'
    );
    $stmt->execute();
    my $users = $stmt->fetchall_arrayref({});

    template 'user_list', {
        common_template_params,
        nav => [
            { name => 'user list', link => undef },
        ],
        color => 'blank',
        users => $users,
    }
};

1;
