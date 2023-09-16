package Nix::PerlPackages::Errata;

use v5.38;
use strict;
use Exporter 'import';
our @EXPORT_OK = qw(errata);

sub errata {
        return %errata;
}

# This errata originated from the previously used  cpan2nix tool
our $errata = {
    ignoreModule => [ "URI::_generic",
                      "Catalyst::Engine::CGI",
                      "Catalyst::Engine::FastCGI",
                      "Catalyst::Engine::HTTP",
                      "Catalyst::Engine::HTTP::Restarter",
                      "Catalyst::Engine::HTTP::Restarter::Watcher" ],
    extraBuildDependencies => {
        "Alien-GMP"               => [ "Devel::CheckLib" ],
        "Autodia"                 => [ "DBI" ],
        "Array-FIFO"              => [ "Test::Trap", "Test::Deep::NoTest" ],
        "Archive-Zip"             => [ "Test::MockModule" ],
        "Catalyst-Controller-POD" => [ "inc::Module::Install" ],
        "Catalyst-Runtime"        => [ "Type::Tiny" ],
        "Catalyst-Authentication-Store-DBIx-Class" => [ "Test::Warn" ],
        "Catalyst-Authentication-Store-Htpasswd"   =>
          [ "Test::WWW::Mechanize", "Test::LongString" ],
        "Catalyst-Controller-HTML-FormFu" => [ "Test::LongString" ],
        "Catalyst-Controller-POD"         => [
            "Test::WWW::Mechanize", "Test::LongString", "inc::Module::Install"
        ],
        "Catalyst-Plugin-Cache"      => [ "Class::Accessor" ],
        "Catalyst-Plugin-Cache-HTTP" =>
          [ "Test::WWW::Mechanize", "Test::LongString" ],
        "Catalyst-View-Download" =>
          [ "Test::WWW::Mechanize", "Test::LongString" ],
        "Code-TidyAll" => [
            "Test::Class", "Test::Deep", "Test::Exception", "Test::Most",
            "Test::Warn"
        ],
        "Corona"             => [ "Test::SharedFork", "Test::TCP" ],
        "CPAN"               => [ "Archive::Zip" ],
        "Crypt-SSLeay"       => [ "Path::Class" ],
        "Data-FormValidator" => [ "CGI" ],
        "Data-Page-Pageset"  =>
          [ "Class::Accessor", "Data::Page", "Test::Exception" ],
        "Data-Taxi"                          => [ "Debug::ShowStuff" ],
        "DateTime-Calendar-Julian"           => [ "DateTime" ],
        "DBIx-Introspector"                  => [ "Test::Fatal" ],
        "Dist-Zilla-Plugin-CheckChangeLog"   => [ "Test::Deep" ],
        "Dist-Zilla-Plugin-ReadmeAnyFromPod" => [
            "Test::SharedFork", "Test::Differences",
            "Test::Exception",  "Test::Warn"
        ],
        "Dist-Zilla-Plugin-ReadmeMarkdownFromPod" => [
            "Test::Deep", "Test::Differences", "Test::Exception", "Test::Warn"
        ],
        "Dist-Zilla-Plugin-Test-CPAN-Changes"   => [ "Test::Deep" ],
        "Dist-Zilla-Plugin-Test-CPAN-Meta-JSON" => [ "Test::Deep" ],
        "Dist-Zilla-Plugin-Test-DistManifest"   => [ "Test::Deep" ],
        "Dist-Zilla-Plugin-Test-MinimumVersion" => [ "Test::Deep" ],
        "Dist-Zilla-Plugin-Test-Perl-Critic"    => [ "Test::Deep" ],
        "Dist-Zilla-Plugin-Test-Synopsis"       => [ "Test::Deep" ],
        "Dist-Zilla-Plugin-Test-UnusedVars"     => [ "Test::Deep" ],
        "Dist-Zilla-Plugin-Test-Version"        => [ "Test::Deep" ],
        "Font-TTF"                              => [ "IO::String" ],
        "FormValidator-Simple"                  => [ "CGI" ],
        "Gnome2-Canvas" => [ "ExtUtils::PkgConfig", "ExtUtils::Depends" ],
        "Gtk2-TrayIcon" =>
          [ "ExtUtils::PkgConfig", "ExtUtils::Depends", "Glib::CodeGen" ],
        "Gtk2-Unique"       => [ "Glib::CodeGen" ],
        "grepmail"          => [ "File::HomeDir::Unix" ],
        "Hash-Merge-Simple" => [
            "Test::Deep", "Test::Warn", "Test::Exception", "Test::Differences"
        ],
        "HTML-Selector-XPath"    => [ "Test::Base" ],
        "HTML-Tidy"              => [ "Test::Exception" ],
        "HTTP-Response-Encoding" => [ "LWP::UserAgent" ],
        "IO-Socket-Timeout"      => [ "Test::SharedFork" ],
        "JSON"                   => [ "Test::Pod" ],
        "Mail-Mbox-MessageParser" =>
          [ "File::Slurper", "Test::Pod", "Test::Pod::Coverage" ],
        "Module-Build-Pluggable-PPPort" => [ "Test::SharedFork" ],
        "Module-Info"        => [ "Test::Pod", "Test::Pod::Coverage" ],
        "MooseX-Has-Options" => [
            "Test::Deep", "Test::Differences", "Test::Exception", "Test::Warn"
        ],
        "Net-SCP"                      => [ "String::ShellQuote", "Net::SSH" ],
        "PerlIO-via-symlink"           => [ "inc::Module::Install" ],
        "PerlIO-via-Timeout"           => [ "Test::SharedFork" ],
        "Plack"                        => [ "Test::SharedFork" ],
        "Plack-App-Proxy"              => [ "Test::SharedFork" ],
        "Plack-Test-ExternalServer"    => [ "Test::SharedFork" ],
        "Plack-Middleware-Auth-Digest" => [ "Test::SharedFork", "Test::TCP" ],
        "Plack-Middleware-Deflater"    => [ "Test::SharedFork", "Test::TCP" ],
        "Plack-Middleware-Session"     => [ "Test::SharedFork", "Test::TCP" ],
        "Protocol-HTTP2" => [ "Test::SharedFork" ],
        "REST-Utils"     => [ "Test::LongString", "Test::WWW::Mechanize" ],
        "RT-Client-REST" => [
            "CGI",                         "DateTime",
            "DateTime::Format::DateParse", "Error",
            "Exception::Class",            "HTTP::Cookies",
            "LWP::UserAgent",              "Params::Validate",
            "Test::Exception"
        ],
        "Starlet"                     => [ "Test::SharedFork" ],
        "Task-Plack"                  => [ "Test::SharedFork" ],
        "Task-FreecellSolver-Testing" => [ "Test::Trap" ],
        "Term-ProgressBar-Simple"     => [ "Test::MockObject" ],
        "Test-Class-Most"             => [
            "Test::Differences", "Test::Deep", "Test::Exception", "Test::Warn"
        ],
        "Test-Run-Plugin-ColorFileVerdicts" => [ "Test::Trap" ],
        "Test-Run-Plugin-ColorSummary"      => [ "Test::Trap" ],
        "Test-WWW-Mechanize"                => [ "Test::LongString" ],
        "Test-WWW-Mechanize-CGI"            => [ "Test::LongString" ],
        "Test-WWW-Mechanize-PSGI"           => [ "Test::LongString" ],
        "Twiggy"                            => [ "Test::SharedFork" ],
        "Cache-KyotoTycoon"                 => [ "Test::SharedFork" ],
        "YAML"                              => [ "Test::Base" ],
        "Net-IP-Lite"                       => [ "Test::Exception" ],
        "Mojo-Pg"                           => [ "Test::Deep" ],
        "Mojo-mysql"                        => [ "Test::Deep" ],
        "Sereal"                  => [ "Test::Deep", "Test::MemoryGrowth" ],
        "LWP-UserAgent-DNS-Hosts" => [ "Test::TCP",  "Test::SharedFork" ],
        "Net-FreeDB"              => [
            "Test::Most",        "Test::Exception",
            "Test::Differences", "Test::Warn",
            "Test::Deep"
        ],
        "SDL" => [
            "Test::Exception", "Test::Differences", "Test::Warn", "Test::Deep"
        ],
        "Device-MAC" => [
            "Test::Exception", "Test::Differences", "Test::Warn", "Test::Deep"
        ],
        "Device-OUI" => ["Test::Exception"],

    },
      extraRuntimeDependencies => {

        "Alien-Build"                      => [ "PkgConfig" ],
        "Any-Moose"                        => [ "Mouse", "Moose"],
        "Crypt-PKCS10"                     => [ "Convert::ASN1" ],
        "Crypt-SSLeay"                     => [ "LWP::Protocol::https"
                                                "Bytes::Random::Secure" ],
        "GDTextUtil"                       => [ "GD" ],
        "Gtk2-Unique"                      => [ "Cairo", "Pango"],
        "Gtk2-ImageView"                   => [ "Pango" ],
        "Gtk2-TrayIcon"                    => [ "Pango" ],
        "Gtk2-GladeXML"                    => [ "Pango" ],
        "Goo-Canvas"                       => [ "Pango" ],
        "Gnome2-Wnck"                      => [ "Pango" ],
        "Gnome2-Canvas"                    => [ "Glib", "Gtk2", "Pango" ],
        "libxml-perl"                      => [ "XML::Parser" ],
        "Linux-Inotify2"                   => [ "common::sense" ],
        "Log-LogLite"                      => [ "IO::LockedFile" ],
        "Net-SSH-Perl"                     => [ "File::HomeDir" ],
        "Proc-WaitStat"                    => [ "IPC::Signal" ],
        "RSS-Parser-Lite"                  => [ "local::lib" ],
        "Statistics-TTest"                 => [ "Statistics::Distributions",
                                                "Statistics::Descriptive" ],
        "GoferTransport-http"              => [ "mod_perl2" ],
        "Text-WrapI18N"                    => [ "Text::CharWidth" ],
        "Text-SimpleTable"                 => [ "Unicode::GCString" ], # or Text::VisualWidth::UTF8 or Text::VisualWidth::PP
        "XML-SAX"                          => [ "XML::SAX::Exception" ],
        "XML-Grove"                        => [ "Data::Grove" ],
        "XML-Handler-YAWriter"             => [ "XML::Parser::PerlSAX" ],
        "ExtUtils-F77"                     => [ "File::Which" ],
        "CPANPLUS"                         => [ "Archive::Extract", # https://github.com/NixOS/nixpkgs/pull/41394 #issuecomment-394208166
                                                "Log::Message",
                                                "Module::Pluggable",
                                                "Object::Accessor",
                                                "Package::Constants",
                                                "Term::UI" ],
        "JSON-Validator"                   => [ "Data::Validate::Domain", # https://github.com/NixOS/nixpkgs/pull/70335 #issuecomment-538054983
                                                "Data::Validate::IP",
                                                "Net::IDN::Encode",
                                                "YAML::XS" ],
        "Crypt-ScryptKDF"                  => [ "Crypt::OpenSSL::Random" ], # https://github.com/NixOS/nixpkgs/pull/71128
        "DBD-Sybase"                       => [ "DBI" ],
        "CatalystX-Script-Server-Starman"  => [ "MooseX::Types",
                                                "Pod::Parser" ],
        "Device-OUI"                       => [ "Class::Accessor::Grouped",
                                                "Sub::Exporter",
                                                "LWP" ],
        "Crypt-DES_EDE3"                   => [ "Crypt::DES" ], # .meta file is 404
        "CPAN-Mini"                        => [ "LWP::Protocol::https"], # https://github.com/NixOS/nixpkgs/pull/97098 #pullrequestreview-484545271
      }
};

1;
