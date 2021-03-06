#!/usr/bin/perl
use strict;
use warnings;

use Getopt::Long;
use Config::Tiny;
use FindBin qw($Bin);
use File::Copy;
use Cwd;
use FileHandle;
use File::Basename;
use JSON;
use Data::Dumper;
use Log::Log4perl;
Log::Log4perl->init("log4perl.conf");
my $log = Log::Log4perl->get_logger('build.log');

=head1 NAME

make_jbrowse.pl - Creates a JBrowse instance with input GFF and configuration

=head1 SYNOPSYS

  % make_jbrowse.pl --config <conf file> [options]

=head1 OPTIONS

 --config     Path to ini-style config file (required)
 --species    Name of species 
                  (should use same format as ALL_SPECIES.stats)
 --filedir    Path to parent directory where releases and files can be found
 --gfffile    Path to an input GFF file
 --fastafile  Path to an input FASTA file
 --datadir    Relative path (from jbrowse root) to jbrowse data dir
 --jbrowsedir Path to jbrowse directory
 --jbrowserepo Path to jbrowse git checkout
 --nosplit    Don't split GFF file by reference sequence
 --usenice    Run formatting commands with Unix nice 
 --skipfilesplit Don't split files or use grep to make subfiles
 --skipprepare Don't run prepare-refseqs.pl
 --allstats   Path to the ALLSPECIES.stats file
 --simple     Make the C. elegans "simple" config for gene pages
 --quiet      Limit output to errors

=head1 DESCRIPTION

This script will take a GFF file for an organism and create the json
files for JBrowse to consume.

=head2 config

This script uses a fairly simple ini style script.  The options in main
section of the config (before the sections that start with square-bracketed
names) include:

 gfffile   - Path to the input GFF file
 fastafile - Path to the input FASTA file
 filedir   - Path to parent directory where releases and files can be found
 datadir   - Relative path (from the jbrowse root) to jbrowse data directory
 jbrowsedir- Path to JBrowse directory
 jbrowserepo - Path to git checkout of the jbrowse repo
 nosplit   - Don't split GFF file by reference sequence 
 usenice   - Run formatting commands with Unix nice
 skipfilesplit - Don't split files or use grep to make subfiles
 skipprepare - Don't run prepare-refseqs.pl
 allstats  - Path to the ALLSPECIES.stats file
 includes  - Path to the json includes file
 glyphs    - Path to custom JBrowse glyphs
 browser_data - Path to the browser_data directory where modencode files are

Note that the options in the config file can be overridden with the command
line options.

Each stanza that starts with a section name enclosed in square brackets has
several options:

=over 

=item

origfile  - Set to 1 to use the original or split GFF file; this is overridden by the presense of the grep option

=item

grep      - A perl-style regular expression that can be used to create a small, track specific GFF file

=item

prefix    - The string that will be prepended to the original file name when created with the grep option

=item

type      - A comma-separated list of types with optional sources, written "type:source,type2:source2"

=item

label     - The jbrowse label and key for the track

=item

altfile   - The section name that contains the grep-created GFF file for this track (to allow a GFF file created for one track to be reused for another)

=item

postprocess - the name of a script that will perform some sort of post
processing on the created GFF file.  It takes the name of the GFF file
as input and creates a gff file with the same name as the input with
".out" appended.  The script should be in the same directory as this
script.

=item

index    - 0|1, whether or not to include this track when running generate_names to index the names for autocompletion.

=back
 
=head2 nosplit

Some of the formatting steps can take a very long time with large GFF
files, so one of the intermeditate steps the script will take is to
split the GFF file into multiple files based on the reference sequence.
This may be less desirable when the genome consists of 10,000 contigs
than when there are 6 chromosomes.

=head2 usenice

Run all of the commands with the Unix nice command to bump their priority
down in the command scheduler.

=head1 AUTHOR

Scott Cain E<lt>scott@scottcain.netE<gt>

Copyright (c) 2014

This script is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut


my $INITIALDIR = cwd();

my ($GFFFILE, $FASTAFILE, $CONFIG, $DATADIR, $NOSPLITGFF, $USENICE,
    $SKIPFILESPLIT, $JBROWSEDIR, $JBROWSEREPO, $SKIPPREPARE, $ALLSTATS, $FILEDIR,
    $QUIET, $INCLUDES, $FUNCTIONS, $ORGANISMS, $GLYPHS,$SPECIES,
    $RELEASE, $BROWSER_DATA, $FTPHOST, $SIMPLE);
my %splitfiles;

GetOptions(
    'gfffile=s'   => \$GFFFILE,
    'species=s'   => \$SPECIES,
    'filedir=s'   => \$FILEDIR,
    'fastafile=s' => \$FASTAFILE,
    'config=s'    => \$CONFIG,
    'datadir=s'   => \$DATADIR,
    'nosplitgff'  => \$NOSPLITGFF,
    'usenice'     => \$USENICE,
    'skipfilesplit'=>\$SKIPFILESPLIT,
    'jbrowsedir=s'=> \$JBROWSEDIR,
    'jbrowserepo=s'=>\$JBROWSEREPO,
    'skipprepare' => \$SKIPPREPARE,
    'allstats=s'  => \$ALLSTATS,
    'simple'      => \$SIMPLE,
    'quiet'       => \$QUIET,
) or ( system( 'pod2text', $0 ), exit -1 );

system( 'pod2text', $0 ) unless $CONFIG;

my $Config = Config::Tiny->read($CONFIG) or die $!;

my @config_sections = grep {!/^_/} keys %{$Config}; 

$SPECIES  ||= 'c_elegans';
$FILEDIR  ||= $Config->{_}->{filedir} ||='/usr/local/ftp/pub/wormbase/releases/';
$RELEASE  ||= $Config->{_}->{release};
$GFFFILE  ||= $Config->{_}->{gfffile};
$FASTAFILE||= $Config->{_}->{fastafile};
$DATADIR  ||= $Config->{_}->{datadir};
$SKIPFILESPLIT ||= $Config->{_}->{skipfilesplit};
$JBROWSEREPO= $Config->{_}->{jbrowserepo};
$NOSPLITGFF = $Config->{_}->{nosplitgff} unless defined $NOSPLITGFF;
$USENICE    = $Config->{_}->{usenice}    unless defined $USENICE;
$SKIPPREPARE= $Config->{_}->{skipprepare} unless defined $SKIPPREPARE;
$INCLUDES   = $Config->{_}->{includes}  || "$JBROWSEREPO/data/c_elegans/includes";
$FUNCTIONS  = $Config->{_}->{functions} || "$JBROWSEREPO/data/functions.conf";
$ORGANISMS  = $Config->{_}->{organisms} || "$JBROWSEREPO/data/organisms.conf" ;
$GLYPHS     = $Config->{_}->{glyphs}    || "$JBROWSEREPO/src/JBrowse/View/FeatureGlyph";
$BROWSER_DATA = $Config->{_}->{browser_data};
$ALLSTATS ||= $Config->{_}->{allstats};
    $ALLSTATS =~ s/\$RELEASE/$RELEASE/e;
my $nice = $USENICE ? "nice" : '';
$JBROWSEDIR ||=  $Config->{_}->{jbrowsedir};;
$FTPHOST    = 'ftp://ftp.wormbase.org';

if ($SIMPLE) {
    $SPECIES = 'c_elegans_simple';
}

#this will be added to by every track
my @include = ("../functions.conf");

#location of the repo must be defined
die "JBROWSEREPO must be defined" unless (-e $JBROWSEREPO);

#parse all stats
die "allstats must be defined" unless (-e $ALLSTATS);

open AS, $ALLSTATS or die $!;
my $firstline = <AS>;
chomp $firstline;
my @columnnames = split /\t/, $firstline;

my @fullspecies_id = grep { /^$SPECIES/ } @columnnames;

if (@fullspecies_id > 1) {
    print STDERR <<END

The species you specified on the command line has more than
one data set associated with it. Please rerun the command
and specify one of these:
END
;

    print STDERR "  ".join("\n  ",@fullspecies_id)."\n\n";
    exit(1);
}
my $species = $fullspecies_id[0];
$species    = 'c_elegans_simple' if $SIMPLE;
die "No matching species found: $SPECIES\n" unless $species;

$DATADIR  ||= "data/$species";
my %speciesdata;

#parse the rest of the file
while (my $line = <AS>) {
    chomp $line;
    my @la = split /\t/, $line;

    my $track;
    if($la[3] =~ /\((\S+?)\)$/ ) {
        $track = $1;
    }
    else {
        next; #if there's no config for this track, goto next line
    }

    for (my $i=0;$i<scalar(@la);$i++) {
        next unless $la[$i];
        $speciesdata{$columnnames[$i]}{$track} = $la[$i];
    }
}
close AS;

print "Processing $species ...\n";


process_data_files() unless $SIMPLE;


chdir $JBROWSEDIR or die $!." $JBROWSEDIR\n";

if ($SIMPLE) {
    mkdir $DATADIR unless -e $DATADIR;
    #make a bunch of symlinks to the main elegans site
    symlink "../c_elegans_PRJNA13758/includes"   , "$DATADIR/includes";
    symlink "../c_elegans_PRJNA13758/names"      , "$DATADIR/names";
    symlink "../c_elegans_PRJNA13758/seq"        , "$DATADIR/seq";
    symlink "../c_elegans_PRJNA13758/tracks"     , "$DATADIR/tracks";
    symlink "../c_elegans_PRJNA13758/tracks.conf", "$DATADIR/tracks.conf";
}

#check to see if the seq directory is present; if not prepare-refseqs
if (!-e $DATADIR."/seq" and !$SKIPPREPARE) {
    my $command = "bin/prepare-refseqs.pl --fasta $INITIALDIR"."/"."$FASTAFILE --out $DATADIR";
    system("$nice $command") == 0 or $log->error( $!);
}
push @include, "includes/DNA.json";

#make a symlink to the organisms include file
unless (-e "$DATADIR/../organisms.conf") {
    symlink $ORGANISMS, "$DATADIR/../organisms.conf" or $log->error( $!);
}
unless (-e "browser_data") {
    symlink $BROWSER_DATA, "browser_data" or $log->error( $!);
}

#create several links in the main dir
if (!-e "$JBROWSEDIR/full.html") {
    symlink "$JBROWSEREPO/full.html",    "$JBROWSEDIR/full.html";
    unlink  "$JBROWSEDIR/index.html";
    symlink "$JBROWSEREPO/index.html",   "$JBROWSEDIR/index.html";
    unlink  "$JBROWSEDIR/jbrowse.conf";
    symlink "$JBROWSEREPO/jbrowse.conf", "$JBROWSEDIR/jbrowse.conf";
    symlink "/usr/local/wormbase/website-shared-files/images", "$JBROWSEDIR/images";
    symlink "$JBROWSEREPO/plugins/fullscreen-jbrowse",         "$JBROWSEDIR/plugins/fullscreen-jbrowse";
    symlink "$JBROWSEREPO/plugins/HideTrackLabels",            "$JBROWSEDIR/plugins/HideTrackLabels";
}


#use original or split gff for many tracks
for my $section (@config_sections) {
    next unless $Config->{$section}->{origfile};

    $log->warn( $section) unless $QUIET;
    my $type   = $Config->{$section}->{type};
    my $label  = $Config->{$section}->{label};

    for my $file (keys %splitfiles) {
        my $gfffile = $INITIALDIR ."/". $file;
        my $command = "$nice bin/flatfile-to-json.pl --compress --gff $gfffile --out $DATADIR --type \"$type\" --trackLabel \"$label\"  --trackType CanvasFeatures --key \"$label\" --maxLookback 1000000";
        $log->warn( $command) unless $QUIET;
        system($command) ==0 or $log->error( $!);
    }

    if (!-e "$INCLUDES/$section.json") {
        $log->error( "\nMISSING INCLUDE FILE: $section.json");
    }
    push @include, "includes/$section.json";
}

#use grep-created files for specific tracks
#first process tracks that will be name indexed
for my $section (@config_sections) {
    next unless $Config->{$section}->{index} == 1;
    next unless $speciesdata{$species}{$section};
    process_grep_track($Config, $section);
    $speciesdata{$species}{$section} = -1;
}

#run indexing
system("$nice bin/generate-names.pl --out $DATADIR --compress");

#process the rest of the tracks

for my $section (@config_sections) {
    next if $Config->{$section}->{index} == 1;
    next unless $speciesdata{$species}{$section};
    process_grep_track($Config, $section);
    $speciesdata{$species}{$section} = -1;
}


#check for species-specific include files
my $only_species_name;
if ($species =~ /^(\w_[a-z]+)_/) {
    $only_species_name = $1;
    $only_species_name = 'simple' if $SIMPLE;
}
if ($only_species_name) {
    my @species_specific = glob("$INCLUDES/$only_species_name"."*");
    for (@species_specific) {
        #ack, in place edit of array elements
        $_ = "includes/".basename($_);
    }
    push @include, @species_specific;
}
if ($only_species_name eq 'c_elegans') {
    my @modencode = glob("$INCLUDES/modencode*");
    for (@modencode) {
        $_ = "includes/".basename($_);
    }
    push @include, @modencode;
}


#create trackList data structure:
my $struct = {
    "tracks" => [],
    "names" => { "url" => "names/", "type" => "Hash" },
    "include" => \@include,
    "dataset_id" => "$species",
    "formatVersion" => 1
};
my $json = JSON->new->pretty(1)->encode($struct);

#print out trackList.json
if (-e "$DATADIR/trackList.json") {
    move("$DATADIR/trackList.json","$DATADIR/trackList.json.old");
}

#make a symlink to the includes dir
unless (-e "$DATADIR/includes") {
    symlink $INCLUDES, "$DATADIR/includes" or $log->error( $!);
}
#make a symlink to the functions
unless (-e "$DATADIR/../functions.conf") {
    symlink $FUNCTIONS, "$DATADIR/../functions.conf" or $log->error( $!); 
}



open TL, ">$DATADIR/trackList.json" or die $!;
print TL $json; 
close TL;


#make symlinks for custom glyphs
chdir $GLYPHS;
my @files = glob("*.js");
foreach my $file (@files) {
    unless (-e "$JBROWSEDIR/src/JBrowse/View/FeatureGlyph/$file") {
        symlink "$GLYPHS/$file", "$JBROWSEDIR/src/JBrowse/View/FeatureGlyph/$file" or $log->error( $!);
    }
}

#if this is elegans make links to the modencode data
if (!$SIMPLE && $SPECIES =~ /c_elegans/) {
    chdir "$DATADIR/tracks" or $log->error( "changing to tracks dir didn't work");    
    system("$Bin/track_links.sh") == 0 or $log->error( "creating track symlinks didn't work");
}

#clean up temporary gff files
chdir $INITIALDIR;
my @tmp_gffs = glob("*_$GFFFILE*") if $GFFFILE;
foreach my $file (@tmp_gffs) {unlink $file;} 

#check for tracks that have data but didn't get processed
for my $key (keys $speciesdata{$species}) {
    next if $speciesdata{$species}{$key} == -1;
    $log->error( "\n\nWARNING: TRACK WITH DATA BUT NO CONFIG: $key\n\n");
}

exit(0);


sub process_grep_track {
    my $config = shift;
    my $section= shift;

    next if $config->{$section}->{origfile};

    my $gffout;
    my $postprocess;
    my $altsection = $config->{$section}->{altfile};
    if ($altsection) {
        $gffout = $INITIALDIR ."/". $config->{$altsection}->{prefix} . "_$GFFFILE";
        $postprocess = $config->{$altsection}->{postprocess};
    }
    else {
        $gffout = $INITIALDIR ."/". $config->{$section}->{prefix} . "_$GFFFILE";
        $postprocess = $config->{$section}->{postprocess};
    }

    if ($postprocess) {
        $gffout = $gffout.".out";
    }
    

    my $type   = $config->{$section}->{type};
    my $label  = $config->{$section}->{label};
    my $command= "$nice bin/flatfile-to-json.pl --compress --gff $gffout --out $DATADIR --type \"$type\" --trackLabel \"$label\"  --trackType CanvasFeatures --key \"$label\"";
    $log->warn( $command) unless $QUIET;

    system($command)==0 or $log->error( "$gffout: $!\n") ;

    if (!-e "$INCLUDES/$section.json") {
        $log->error( "\nMISSING INCLUDE FILE: $section.json\n\n");
    }
    push @include, "includes/$section.json";

    return;
}

sub process_data_files {

#fetch the GFF and fasta files
$species =~ /(\w_\w+?)_(\w+)$/;
my $speciesdir = $1;
my $projectdir = $2;
my $datapath = $FILEDIR . 'WS' . $RELEASE . '/species/' . $speciesdir . '/' . $projectdir;
$GFFFILE   = "$speciesdir.$projectdir.WS$RELEASE.annotations.gff3";
$FASTAFILE = "$speciesdir.$projectdir.WS$RELEASE.genomic.fa";

my $copyfailed = 0;
copy("$datapath/$GFFFILE.gz", '.') or $copyfailed = 1;
copy("$datapath/$FASTAFILE.gz", '.') or $copyfailed = 1;

if ($copyfailed == 1 and !$SIMPLE) {
    die;
    #use ftp to fetch them

    my $ftpgffpath = "/pub/wormbase/releases/WS$RELEASE/species/$speciesdir/$projectdir";

    my $gff = "$ftpgffpath/$GFFFILE.gz";
    my $fasta = "$ftpgffpath/$FASTAFILE.gz";

    my $quiet = $QUIET ? '-q' : '';
    system("wget $quiet $FTPHOST$gff");
    system("wget $quiet $FTPHOST$fasta");
}

system("gunzip -f $GFFFILE.gz");
system("gunzip -f $FASTAFILE.gz");

(-e $GFFFILE)   or die "No GFF file: $GFFFILE";
(-e $FASTAFILE) or die "No FASTA file: $FASTAFILE";

#use grep to create type specific gff files
unless ($SKIPFILESPLIT) {
  for my $section (@config_sections) {

    next unless $speciesdata{$species}{$section};

    my $alt=$Config->{$section}->{altfile};

    my $key = $alt ? $alt : $section;

    my $gffout      ||= $Config->{$key}->{prefix} . "_$GFFFILE";
    my $greppattern ||= $Config->{$key}->{grep};
    my $postprocess ||= $Config->{$key}->{postprocess};

    next if (-e $gffout);

    $greppattern or next;

    my $grepcommand = "grep -P \"$greppattern\" $GFFFILE > $gffout";
    $log->warn( $grepcommand) unless $QUIET;
    system ("$nice $grepcommand") == 0 or $log->error( "$GFFFILE: $!");

    if ($postprocess) {
        system("$nice $Bin/$postprocess $gffout") == 0 or $log->error( "postpressing $gffout: $!");
    }
  }
}

#split the primary GFF file by seq_id if desired.
if (!$NOSPLITGFF) {
    open GFFIN, "<", $GFFFILE or die "couldn't open $GFFFILE for reading: $!";

    while (<GFFIN>) {
        last if (/^##FASTA/);

        if (/^##sequence-region\s+(\w+)\s/) {
            my $filename = $1.".".$GFFFILE;
            unless ( defined $splitfiles{ $filename } ) {
                $splitfiles{ $filename } = new FileHandle $filename, "w";
            }
            $splitfiles{ $filename }->print( $_ );
            next;
        }

        my @la = split /\t/;

        ($log->warn( "ignored gff line: $_") && next) if (scalar @la != 9);

        my $filename = $la[0].".".$GFFFILE;
        unless ( defined $splitfiles{ $filename } ) {
            $splitfiles{ $filename } = new FileHandle $filename, "w";
        }
        $splitfiles{ $filename }->print( $_ );
    }

    for my $key (keys %splitfiles) {
        $splitfiles{$key}->close;
    }
}
else {
    $splitfiles{$GFFFILE} = 1;
}

return;
}
