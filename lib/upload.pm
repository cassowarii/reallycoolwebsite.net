package linkgarden;
use strict;
use warnings;
use utf8;

use v5.16;

use Dancer2 appname => 'linkgarden';
use Dancer2::Plugin::Database;
use Dancer2::Plugin::Auth::Extensible;

use Image::Magick;

use List::Util qw( min max );

use constant PUBLIC_DIRECTORY => '/home/cassowa4/linkgarden/public/';
use constant UPLOAD_DIRECTORY => 'user_pics/';

my $max_img_width = 150;
my $max_img_height = 150;

# This will generate silly toki-pona-like pronounceable
# filenames, because I think it's funny. Of course the issue
# with pronounceable auto-generated filenames is the possibility
# of generating offensive words lol. I believe the CVCVCV
# structure and limited consonant inventory should prevent
# it from generating offensive words (fingers crossed lol)
sub gen_filename {
    my $name = '';

    for (1..12) {
        my @c = ('n', 'm', 'k', 't', 'p', 'j', 'l', 's', 'w');
        @c = ('k', 't', 'p', 'j', 'l', 's', 'w') if $name =~ /n$/; # nm disallowed
        push @c, '' if $name =~ /-$/ || $_ == 1;
        $name .= $c[rand @c];

        # toki pona phonotactics
        my @v = ('a', 'e', 'i', 'o', 'u');
        @v = ('a', 'e', 'i') if $name =~ /w$/; # wo, wu disallowed
        @v = ('a', 'e', 'o', 'u') if $name =~ /[jt]$/; # ji, ti disallowed
        $name .= $v[rand @v];

        if ((rand 10) > 9) {
            $name .= 'n';
        }

        if (rand 3 < 1 and $_ != 12) {
            $name .= '-';
        }
    }

    return $name;
}

# Takes a Dancer2 'upload' object, scales the image down to
# postage stamp size, and moves it into the user_pics
# directory.
sub handle_upload {
    my ($upload) = @_;

    my $tempname = $upload->tempname;
    my $upload_path;
    do {
        $upload_path = UPLOAD_DIRECTORY . gen_filename() . '.png';
    } while (-f PUBLIC_DIRECTORY . $upload_path or $upload_path =~ /jew/);

    my $im = Image::Magick->new;
    my $result = $im->Read($tempname);
    die "Failed to get uploaded image: $result" if $result;

    # Figure out how much we need to scale down in order to
    # get the image within 150x150, preserving aspect ratio --
    # we calculate what the max size would be as a % of the
    # image size, if it's less than 100% we use that percentage,
    # then we find out if the width or height is the limiting
    # factor
    my ($w, $h) = $im->Get('width', 'height');
    my $wscale = min($max_img_width / $w, 1);
    my $hscale = min($max_img_height / $h, 1);
    my $scale = min($wscale, $hscale);

    # why is the imagemagick interface insane pls help
    my $geometry = sprintf "%0fx%0f", $w * $scale, $h * $scale;
    $result = $im->Scale(geometry => $geometry);
    die "Failed to scale image: $result" if $result;

    say {\*STDERR} "Writing to: ", PUBLIC_DIRECTORY . $upload_path;

    $result = $im->Write(filename => PUBLIC_DIRECTORY . $upload_path);
    die "Failed to write resized image: $result" if $result;

    database('link_creator')->quick_insert('linkgarden_uploads', {
        url => $upload_path,
        owner => logged_in_user->{id},
    });

    return $upload_path;
}
