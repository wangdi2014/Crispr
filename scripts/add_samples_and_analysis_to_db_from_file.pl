#!/usr/bin/env perl

# PODNAME: add_samples_and_analysis_to_db_from_file.pl
# ABSTRACT: Add information about samples and analysis information
# to a CRISPR SQL database from a sample manifext file.

use warnings;
use strict;
use Getopt::Long;
use autodie;
use Pod::Usage;
use English qw( -no_match_vars );
use List::MoreUtils qw( none );

use Crispr::DB::DBConnection;
use Crispr::DB::Plex;
use Crispr::DB::SampleAmplicon;
use Crispr::DB::Analysis;
use Crispr::DB::Sample;
use Crispr::Plate;
use Labware::Plate;

# get options
my %options;
get_and_check_options();

# connect to db
my $db_connection = Crispr::DB::DBConnection->new( $options{crispr_db}, );
my $plex_adaptor = $db_connection->get_adaptor( 'plex' );
my $injection_pool_adaptor = $db_connection->get_adaptor( 'injection_pool' );
my $analysis_adaptor = $db_connection->get_adaptor( 'analysis' );
my $sample_adaptor = $db_connection->get_adaptor( 'sample' );
my $primer_pair_adaptor = $db_connection->get_adaptor( 'primer_pair' );

# set up barcode and sample plates
my $barcode_plates = set_up_barcode_plates();

# make a minimal plate for parsing well-ranges
my $sample_plate = Crispr::Plate->new(
    plate_category => 'samples',
    plate_type => $options{sample_plate_format},
    fill_direction => $options{sample_plate_fill_direction},
);

# Create Plex object and check it exists in the db
my $plex;
eval {
    $plex = $plex_adaptor->fetch_by_name( $options{plex_name} );
};
if( $EVAL_ERROR ){
    if( $EVAL_ERROR =~ qr/Couldn't retrieve plex, $options{plex_name}, from database./ ){
        $plex = Crispr::DB::Plex->new(
            plex_name => $options{plex_name},
            run_id => $options{run_id},
            analysis_started => $options{analysis_started},
            analysis_finished => $options{analysis_finished},
        );
        $plex_adaptor->store( $plex );
    }
    else{
        die $EVAL_ERROR, "\n";
    }
}

# parse input file, create Sample objects and add them to db
my @attributes = ( qw{injection_name sample_wells generation sample_type species
cryo_box sample_plate_num wells barcodes barcode_plate_num amplicons } );

my @required_attributes = ( qw{injection_name generation sample_type species
sample_plate_num wells amplicons } );

my $comment_regex = qr/#/;
my @columns;
my @samples;
# go through input
while(<>){
    my @values;

    chomp;
    if( $INPUT_LINE_NUMBER == 1 ){
        if( !m/\A $comment_regex/xms ){
            die "Input needs a header line starting with a #\n";
        }
        s|$comment_regex||xms;
        @columns = split /\t/, $_;
        my ( $wells, $numbers, $barcodes, $barcode_plate_num );
        foreach my $column_name ( @columns ){
            if( none { $column_name eq $_ } @attributes ){
                die "Could not recognise column name, ", $column_name, ".\n";
            }
            $wells = $column_name eq 'sample_wells' ? 1 : 0;
            $numbers = $column_name eq 'num_samples' ? 1 : 0;
            $barcodes = $column_name eq 'barcodes' ? 1 : 0;
            $barcode_plate_num = $column_name eq 'barcode_plate_num' ? 1 : 0;
        }
        foreach my $attribute ( @required_attributes ){
            if( none { $attribute eq $_ } @columns ){
                die "Missing required attribute: ", $attribute, ".\n";
            }
        }
        if( !( $wells xor $numbers ) ){
            die "Input file must include only one of sample_wells or num_samples!\n";
        }
        if( !( $barcodes xor $barcode_plate_num ) ){
            die "Input file must include only one of barcodes or barcode_plate_num!\n";
        }
    }
    else{
        @values = split /\t/, $_;
    }

    my %args;
    for( my $i = 0; $i < scalar @columns; $i++ ){
        if( $values[$i] eq 'NULL' ){
            $values[$i] = undef;
        }
        $args{ $columns[$i] } = $values[$i];
    }
    warn Dumper( %args ) if $options{debug} > 1;

    # get injection pool object
    $args{'injection_pool'} = $injection_pool_adaptor->fetch_by_name( $args{'injection_name'} );
    # get existing samples
    my $samples = $sample_adaptor->fetch_all_by_injection_pool( $args{'injection_pool'} );

    my @sample_numbers;
    if( @{$samples} ){
        @sample_numbers = sort { $b <=> $a }
                            map { $_->sample_number } @{$samples};
    }
    my $starting_sample_number = @sample_numbers
        ?   $sample_numbers[0]
        :   0;

    my @well_ids;
    if( defined $args{sample_wells} ){
        @well_ids = $sample_plate->parse_wells( $args{sample_wells} );
    }
    my $num_samples = @well_ids ? scalar @well_ids : $args{num_samples};

    my @barcodes;
    if( $args{barcodes} ){
        @barcodes = parse_barcodes( $args{barcodes} );
    }
    elsif( $args{barcode_plate_num} ){
        foreach my $well_id ( @well_ids ){
            my $plate_i = $args{barcode_plate_num} - 1;
            my $barcode = $barcode_plates->[$plate_i]->return_well( $well_id )->contents();
            push @barcodes, $barcode;
        }
    }

    foreach my $sample_number ( $starting_sample_number + 1 .. $starting_sample_number + $num_samples ){
        my $well_id = shift @well_ids;
        $args{'well'} = defined $well_id ? Labware::Well->new( position => $well_id, )
            :       undef;
        # make new sample object
        $args{'sample_name'} = join("_", $args{'injection_name'}, $sample_number, );
        $args{'sample_number'} = $sample_number;
        my $sample = Crispr::DB::Sample->new( \%args );
        push @samples, $sample;
    }
}

if( $options{debug} > 1 ){
    warn Dumper( @samples, );
}

foreach my $sample ( @samples ){
    eval{
        $sample_adaptor->store_sample( $sample );
    };
    if( $EVAL_ERROR ){
        die join(q{ }, "There was a problem storing the sample,",
                $sample->sample_name, "in the database.\n",
                "ERROR MSG:", $EVAL_ERROR, ), "\n";
    }
    else{
        print join(q{ }, 'Sample,', $sample->sample_name . ',',
            'was stored correctly in the database with id:',
            $sample->db_id,
        ), "\n";
    }
}

sub get_and_check_options {

    GetOptions(
        \%options,
		'crispr_db=s',
        'sample_plate_format=s',
        'sample_plate_fill_direction=s',
        'help',
        'man',
        'debug+',
        'verbose',
    ) or pod2usage(2);

    # Documentation
    if( $options{help} ) {
        pod2usage( -verbose => 0, -exitval => 1, );
    }
    elsif( $options{man} ) {
        pod2usage( -verbose => 2 );
    }

    # default values
    $options{debug} = defined $options{debug} ? $options{debug} : 0;
    if( $options{debug} > 1 ){
        use Data::Dumper;
    }
    $options{sample_plate_format} = defined $options{sample_plate_format} ? $options{sample_plate_format} : '96';
    $options{sample_plate_fill_direction} = defined $options{sample_plate_fill_direction} ? $options{sample_plate_fill_direction} : 'row';

    print "Settings:\n", map { join(' - ', $_, defined $options{$_} ? $options{$_} : 'off'),"\n" } sort keys %options if $options{verbose};
}

__END__

=pod

=head1 NAME

add_samples_to_db_from_sample_manifest.pl

=head1 DESCRIPTION

Script to take a sample manifest file as input and add those samples to an SQL database.


=cut

=head1 SYNOPSIS

    add_samples_to_db_from_sample_manifest.pl [options] filename(s) | STDIN
        --crispr_db                         config file for connecting to the database
        --sample_plate_format               plate format for sample plate (96 or 384)
        --sample_plate_fill_direction       fill direction for sample plate (row or column)
        --help                              print this help message
        --man                               print the manual page
        --debug                             print debugging information
        --verbose                           turn on verbose output


=head1 ARGUMENTS

=over

=item B<input>

Sample manifest. Can be a list of filenames or on STDIN.

Should contain the following columns in this order:
barcode, plex_name, plate_num, well_id, injection_name, generation, sample_type, species

=back

=head1 OPTIONS

=over 8

=item B<--crispr_db file>

Database config file containing tab-separated key value pairs.
keys are:

=over

=item driver

mysql or sqlite

=item host

database host name (MySQL only)

=item port

database host port (MySQL only)

=item user

database host user (MySQL only)

=item pass

database host password (MySQL only)

=item dbname

name of the database

=item dbfile

path to database file (SQLite only)

=back

The values can also be set as environment variables
At the moment MySQL is assumed as the driver for this.

=over

=item MYSQL_HOST

=item MYSQL_PORT

=item MYSQL_USER

=item MYSQL_PASS

=item MYSQL_DBNAME

=back

=back

=over

=item B<--sample_plate_format>

plate format for sample plate (96 or 384)
default: 96

=item B<--sample_plate_fill_direction>

fill direction for sample plate (row or column)
default: row

=item B<--debug>

Print debugging information.

=item B<--help>

Print a brief help message and exit.

=item B<--man>

Print this script's manual page and exit.

=back

=head1 DEPENDENCIES

Crispr

=head1 AUTHOR

=over 4

=item *

Richard White <richard.white@sanger.ac.uk>

=back

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2014 by Genome Research Ltd.

This is free software, licensed under:

  The GNU General Public License, Version 3, June 2007

=cut
