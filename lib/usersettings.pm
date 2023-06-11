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

use constant USERSETTINGS_TITLE => "User settings &mdash; reallycoolwebsite.net";
use constant USERSETTINGS_NAV => [ { name => "user settings", link => undef } ];

sub common_settings_params() {
    my %optional;

    if (logged_in_user->{disable_youtube_embeds}) {
        $optional{disable_youtube} = 1;
    }

    if (logged_in_user->{enable_default_comments}) {
        $optional{enable_default_comments} = 1;
    }

    return (
        common_template_params(),
        nav => USERSETTINGS_NAV,
        title => USERSETTINGS_TITLE,
        email => logged_in_user->{email},
        %optional,
    );
}

get '/user-settings/?' => require_login sub {
    template 'user_settings' => {
        common_settings_params,
    };
};

# Function that updates user settings.
post '/user-settings/?' => require_login sub {

    # -- VALIDATE FIRST BEFORE UPDATING --

    my $old_password = body_parameters->get('old_password');
    my $new_password = body_parameters->get('password');
    my $confirm_password = body_parameters->get('confirm_password');
    my $email = body_parameters->get('email');
    my $enable_default_comments = defined body_parameters->get('enable_default_comments') || 0;
    my $disable_youtube = 1;
    if (defined body_parameters->get('inline_youtube')) {
        $disable_youtube = 0;
    }

    # Changing user password
    if ($old_password or $new_password or $confirm_password) {
        # Make sure the user entered both an old and a new password.
        if (not $old_password or not $new_password) {
            return template 'user_settings' => {
                common_settings_params,
                flash_icon => 'error',
                flash_msg => 'Please enter both your old and new password.',
            };
        }

        if (not $confirm_password) {
            return template 'user_settings' => {
                common_settings_params,
                flash_icon => 'error',
                flash_msg => 'Please confirm your new password!',
            };
        }

        if ($confirm_password ne $new_password) {
            if (not $confirm_password) {
                return template 'user_settings' => {
                    common_settings_params,
                    flash_icon => 'error',
                    flash_msg => 'The two new passwords you entered do not match.',
                };
            }
        }

        eval {
            validate_password $new_password;
        }; if (my $error = $@) {
            # Password is too short or something
            return template 'user_settings' => {
                common_settings_params,
                flash_icon => 'error',
                flash_msg => $error,
            };
            return;
        }
    }

    if ($email) {
        eval {
            validate_email $email;
        }; if (my $error = $@) {
            # Email bad
            return template 'user_settings' => {
                common_settings_params,
                flash_icon => 'error',
                flash_msg => $error,
            };
        }
    }

    # -- okay now we validated, now we can actually update stuff --

    my @messages;

    if ($old_password and $new_password and $confirm_password and $new_password eq $confirm_password) {
        # Change password
        my $pwchange_result = user_password password => $old_password,
                                            new_password => $new_password;
        if ($pwchange_result ne logged_in_user->{name}) {
            # Just kidding, it didn't work bc wrong old password. This is the last validation.
            return template 'user_settings' => {
                common_settings_params,
                flash_icon => 'error',
                flash_msg => 'Sorry, the old password you entered was incorrect.',
                email => $email,
            };
        }

        push @messages, 'Password updated.';
    }

    if ($email and $email ne logged_in_user->{email}) {
        my $stmt = database('link_creator')->prepare(
            'UPDATE linkgarden_users SET email = ? WHERE id = ?'
        );
        $stmt->execute($email, logged_in_user->{id});
        update_current_user email => $email;

        push @messages, 'Email updated!';
    }

    if ($disable_youtube != logged_in_user->{disable_youtube_embeds}) {
        update_current_user disable_youtube_embeds => $disable_youtube;

        push @messages, 'YouTube embed settings updated';
    }

    if (logged_in_user->{enable_default_comments} != $enable_default_comments) {
        my $stmt = database('link_creator')->prepare(
            'UPDATE linkgarden_users SET enable_default_comments = ? WHERE id = ?'
        );
        $stmt->execute($enable_default_comments, logged_in_user->{id});
        update_current_user enable_default_comments => $enable_default_comments;

        push @messages, 'Default comment settings updated.';
    }

    if (!@messages) {
        push @messages, 'Nothing was changed.';
    }

    # If multiple messages, display them in a list, otherwise display just the one
    my $flash_msg;
    if (@messages == 1) {
        $flash_msg = $messages[0];
    } else {
        $flash_msg = '<ul>' . (join "", map { "<li>$_</li>" } @messages) . '</ul>';
    }

    template 'user_settings' => {
        common_settings_params,
        flash_icon => 'check',
        flash_msg => $flash_msg,
    };
};
