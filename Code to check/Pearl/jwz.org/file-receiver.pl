#!/usr/bin/perl -w
# Copyright © 2011 Jamie Zawinski <jwz@jwz.org>
#
# Permission to use, copy, modify, distribute, and sell this software and its
# documentation for any purpose is hereby granted without fee, provided that
# the above copyright notice appear in all copies and that both that
# copyright notice and this permission notice appear in supporting
# documentation.  No representations are made about the suitability of this
# software for any purpose.  It is provided "as is" without express or 
# implied warranty.
#
# Receives an email message on stdin, extracts the attachments in it, and dumps
# them in the directory specified on the command line.  Zip files are unpacked.
#
# This is useful when someone has mailed you an attachment, and you need to
# move it from your iPhone or iPad to the server: you can just forward that
# message to a secret email address to have it unpacked.
#
# When the mail server runs this script, you need to arrange for it to run
# as a user who can create files in that directory.  To make this work with
# Postfix:
#
#   /etc/postfix/main.cf:
#     alias_maps     = hash:/etc/aliases, hash:/etc/postfix/aliases-jwz
#     alias_database = hash:/etc/aliases, hash:/etc/postfix/aliases-jwz
#
#   /etc/postfix/aliases-jwz:
#     secret_addr: "|/Users/jwz/www/hacks/file-receiver.pl /var/www/TMP/"
#
#   chown root:wheel /etc/postfix/aliases-jwz*
#   newaliases
#   chown jwz /etc/postfix/aliases-jwz*
#     (this must be done after newaliases!)
#
# Created: 22-Mar-2011.

require 5;
use diagnostics;
use strict;

use MIME::Parser;
use MIME::Entity;

my $progname = $0; $progname =~ s@.*/@@g;
my ($version) = ('$Revision: 1.3 $' =~ m/\s(\d[.\d]+)\s/s);

$ENV{PATH} = "/opt/local/bin:$ENV{PATH}";   # macports

my $verbose = 0;
my $debug_p = 0;


sub save_attachment($$$) {
  my ($name, $data, $output_dir) = @_;

  $name = lc($name);
  $name =~ s/[^-_.a-z\d]/_/gsi;  # map stupid characters to underscores

  # Add a numeric suffix before the extension until we have a unique one.
  #
  while (-f "$output_dir/$name") {
    my ($head, $n, $tail) = ($name =~ m@^(.*?)(-\d+)?(\.[^.]+)$@s);
    $n = ($n || 0) - 1;
    $name = "$head$n$tail";
  }

  if ($debug_p) {
    print STDERR "$progname: not writing $name\n"
      if ($verbose);
  } else {
    chdir ($output_dir) || error ("$output_dir: $!");
    umask 022;

    open (my $out, '>', $name) || error ("$name: $!");
    (print $out $data)         || error ("$name: $!");
    close $out                 || error ("$name: $!");
    print STDERR "$progname: wrote $name\n"
      if ($verbose);
  }

  if ($name =~ m/\.zip$/si) {
    my @cmd = ("unzip", 
               "-j",          # do not create subdirs
               "-L",          # downcase file names
             # "-B",          # backup existing files with ~
               "-o",          # overwrite
               "-qq",         # quiet
               $name,
               "-x", "*/.*",  # exclude dot files e.g. "__MACOSX/._crud.tif"
               );
    if ($debug_p) {
      print STDERR "$progname: not running: " . join(' ', @cmd) . "\n"
        if ($verbose);
    } else {
      print STDERR "$progname: exec: " . join(' ', @cmd) . "\n"
        if ($verbose);
      system @cmd unless ($debug_p);
    }
  }
}


# Recursively processes the MIME::Entity, handling multipart entities.
# Extracts each non-text attachment encountered.
#
sub process_part($$$);
sub process_part($$$) {
  my ($part, $output_dir, $depth) = @_;
  my $type = lc($part->effective_type);
  my $body = $part->bodyhandle;
  my @result = ();

  print STDERR "$progname: " . ("  " x $depth) .
    "Content-Type: $type\n" if ($verbose > 1);

  if ($type =~ m@^text/@si) {			# Ignore

  } elsif ($type =~ m@^multipart/@si) {		# Recurse
    foreach my $subpart ($part->parts) {
      process_part ($subpart, $output_dir, $depth+1);
    }
  } else {					# Extract

    my $name = $part->head->recommended_filename;
    $name = "unknown $type" unless $name;
    save_attachment ($name, $part->bodyhandle->as_string(),
                     $output_dir);
  }

  return @result;
}


sub extract_message($) {
  my ($output_dir) = @_;

  my $ent;
  {
    my $parser = new MIME::Parser;
    $parser->ignore_errors(1);
    $parser->tmp_to_core(1);
    $parser->output_to_core(1);
    eval { $ent = $parser->parse(\*STDIN); };
    my $err = ($@ || $parser->last_error);
    $parser->filer->purge;
    error ("parse failed: $err") if ($err);
  }

  if ($debug_p > 1) {
    print STDERR ("#" x 72) . "\nSource message:\n" . ("#" x 72) . "\n";
    $ent->print(\*STDERR);
    print STDERR "\n" . ("#" x 72) . "\n";
  }

  process_part ($ent, $output_dir, 0);
}


sub error($) {
  my ($err) = @_;
  print STDERR "$progname: $err\n";
  exit 1;
}

sub usage() {
  print STDERR "usage: $progname [--verbose] [--debug] output-dir\n";
  exit 1;
}

sub main() {
  my $output_dir;

  while ($#ARGV >= 0) {
    $_ = shift @ARGV;
    if (m/^--?verbose$/) { $verbose++; }
    elsif (m/^-v+$/) { $verbose += length($_)-1; }
    elsif (m/^--?debug$/) { $debug_p++; }
    elsif (m/^-./) { usage; }
    elsif (! $output_dir) { $output_dir = $_; }
    else { usage; }
  }

  usage() unless $output_dir;
  error ("$output_dir does not exist") unless (-d $output_dir);

#  if ($debug_p > 1) {
#    my $f = "/tmp/file-receiver.log";
#    unlink $f;
#    print STDERR "$progname: logging to $f\n";
#    open (STDOUT, ">$f") || error ("$f: $!");
#    *STDERR = *STDOUT;
#  }

  extract_message ($output_dir);
}

main();
exit 0;
