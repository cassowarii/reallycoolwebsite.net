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
use basicpages;
use userpages;
use posting;
use tagging;
use hearting;
use commenting;
use usersettings;
use registration;
use rss;

our $VERSION = '0.1';

set session => 'YAML';

1;
