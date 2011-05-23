package Games::Construder::Server::ChunkManager;
use common::sense;
use Games::Construder::Server::World;
use Games::Construder::Vector;
use Compress::LZF;
use JSON;
use AnyEvent::Util;
use Time::HiRes qw/time/;
use Carp qw/confess/;

=head1 NAME

Games::Construder::Server::ChunkManager - desc

=head1 SYNOPSIS

=head1 DESCRIPTION

=head1 METHODS

=over 4

=item my $obj = Games::Construder::Server::ChunkManager->new (%args)

=cut

our $CHUNK_SIZE = 12;
our $CHUNKS_P_SECTOR = 5;

sub new {
   my $this  = shift;
   my $class = ref ($this) || $this;
   my $self  = { @_ };
   bless $self, $class;

   return $self
}

sub init {
   my ($self) = @_;
   $self->{store_schedule} = AE::timer 0, 2, sub {
      NEXT:
      my $s = shift @{$self->{save_sectors}}
         or return;
      if ($self->{sector}->{$s->[0]}->{dirty}) {
         $self->save_sector ($s->[1]);
      } else {
         goto NEXT;
      }
   };
}

sub check_adjacent_sectors_at {
   my ($self, $pos) = @_;
   my $chnk = world_pos2chnkpos ($pos);

   for my $dx (-2, 0, 2) {
      for my $dy (-2, 0, 2) {
         for my $dz (-2, 0, 2) {
            my $sec   = world_chnkpos2secpos (vaddd ($chnk, $dx, $dy, $dz));
            my $secid = world_pos2id ($sec);
            unless ($self->{sector}->{$secid}) {
               warn "LOAD SECTOR $secid\n";
               my $r = $self->load_sector ($sec);
               if ($r == 0) {
                  $self->make_sector ($sec);
               }
            }
         }
      }
   }
}

sub make_sector {
   my ($self, $sec) = @_;

   my $seed = Games::Construder::Region::get_sector_value (
      $Games::Construder::Server::World::REGION,
      @$sec
   );

   my $seedf = $seed;
   $seed *= 100 ** 3;
   $seed = int ($seed);
   warn "Create sector @$sec, with seed $seed (".sprintf ("%0.5f", $seedf).")\n";


   my $cube = $CHUNKS_P_SECTOR * $CHUNK_SIZE;
   Games::Construder::VolDraw::alloc ($cube);

   Games::Construder::VolDraw::draw_commands (
      q{
        fill_noise 4 2 0.3
        map_range 0.6 1 0 0.2
      },
     { size => $cube, seed => $seed, param => 1 }
   );

   Games::Construder::VolDraw::dst_to_world (@$sec);

   $self->{sector}->{world_pos2id ($sec)} = { created => time };
   $self->save_sector ($sec);

   Games::Construder::World::query_desetup ();
}

sub chunk_changed {
   my ($self, $x, $y, $z) = @_;
   my $sec = world_chnkpos2secpos ([$x, $y, $z]);
   my $id  = world_pos2id ($sec);
   unless (exists $self->{sector}->{$id}) {
      confess "Sector which is not loaded was updated! (chunk $x,$y,$z [@$sec]) $id\n";
   }
   $self->{sector}->{$id}->{dirty} = 1;
   push @{$self->{save_sectors}}, [$id, $sec];
}

sub load_sector {
   my ($self, $sec) = @_;

   my $t1 = time;

   my $id   = world_pos2id ($sec);
   my $mpd  = $Games::Construder::Server::Resources::MAPDIR;
   my $file = "$mpd/$id.sec";

   return 1 if ($self->{sector}->{$id}
                && !$self->{sector}->{$id}->{broken});

   unless (-e $file) {
      return 0;
   }

   if (open my $mf, "<", "$file") {
      binmode $mf, ":raw";
      my $cont = eval { decompress (do { local $/; <$mf> }) };
      if ($@) {
         warn "map sector data corrupted '$file': $@\n";
         return -1;
      }

      warn "read " . length ($cont) . " bytes\n";

      if ($cont =~ /^(.+?)\n\nMAPDATA\s*([^\n]+)\n\n(.+)$/s) {
         my ($metadata, $data) = ($1, $3);
         warn "LENS[$2]\n";
         my ($datalen, @lens) = split /\s+/, $2;

         unless (length ($data) == $datalen) {
            warn "map sector file '$file' corrupted, sector data truncated, "
                 . "expected $datalen bytes, but only got ".length ($data)."!\n";
            return -1;
         }

         my $meta = eval { JSON->new->relaxed->utf8->decode ($metadata) };
         if ($@) {
            warn "map sector meta data corrupted '$file': $@\n";
            return -1;
         }

         $self->{sector}->{$id} = $meta;
         $meta->{load_time} = time;

         my $offs;
         my $first_chnk = world_secpos2chnkpos ($sec);
         my @chunks;
         for my $dx (0..($CHUNKS_P_SECTOR - 1)) {
            for my $dy (0..($CHUNKS_P_SECTOR - 1)) {
               for my $dz (0..($CHUNKS_P_SECTOR - 1)) {
                  my $chnk = vaddd ($first_chnk, $dx, $dy, $dz);

                  my $len = shift @lens;
                  my $chunk = substr $data, $offs, $len;
                  Games::Construder::World::set_chunk_data (
                     @$chnk, $chunk, length ($chunk));
                  $offs += $len;
               }
            }
         }

         delete $self->{sector}->{$id}->{dirty}; # saved with the sector
         warn "loaded sector $id from '$file', took "
              . sprintf ("%.3f seconds", time - $t1)
              . ".\n";

      } else {
         warn "map sector file '$file' corrupted! Please delete or move it away!\n";
         return -1;
      }
   } else {
      warn "couldn't open map sector '$file': $!\n";
      return -1;
   }

}

sub save_sector {
   my ($self, $sec) = @_;

   my $t1 = time;

   my $id   = world_pos2id ($sec);
   my $meta = $self->{sector}->{$id};

   if ($meta->{broken}) {
      warn "map sector '$id' marked as broken, won't save!\n";
      return;
   }

   $meta->{save_time} = time;

   my $first_chnk = world_secpos2chnkpos ($sec);
   my @chunks;
   for my $dx (0..($CHUNKS_P_SECTOR - 1)) {
      for my $dy (0..($CHUNKS_P_SECTOR - 1)) {
         for my $dz (0..($CHUNKS_P_SECTOR - 1)) {
            my $chnk = vaddd ($first_chnk, $dx, $dy, $dz);
            push @chunks,
               Games::Construder::World::get_chunk_data (@$chnk);
         }
      }
   }

   my $meta_data = JSON->new->utf8->pretty->encode ($meta || {});

   my $data = join "", @chunks;
   my $filedata = compress (
      $meta_data . "\n\nMAPDATA "
      . join (' ', map { length $_ } ($data, @chunks))
      . "\n\n" . $data
   );

   my $mpd = $Games::Construder::Server::Resources::MAPDIR;
   my $file = "$mpd/$id.sec";

   if (open my $mf, ">", "$file~") {
      binmode $mf, ":raw";
      print $mf $filedata;
      close $mf;
      unless (-s "$file~" == length ($filedata)) {
         warn "couldn't save sector completely to '$file~': $!\n";
         return;
      }

      if (rename "$file~", $file) {
         delete $self->{sector}->{$id}->{dirty};
         warn "saved sector $id to '$file', took "
              . sprintf ("%.3f seconds", time - $t1)
              . "\n";

      } else {
         warn "couldn't rename '$file~' to '$file': $!\n";
      }

   } else {
      warn "couldn't save sector $id to '$file~': $!\n";
   }
}

=back

=head1 AUTHOR

Robin Redeker, C<< <elmex@ta-sa.org> >>

=head1 SEE ALSO

=head1 COPYRIGHT & LICENSE

Copyright 2009 Robin Redeker, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut

1;
