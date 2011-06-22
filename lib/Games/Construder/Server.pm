package Games::Construder::Server;
use common::sense;
use AnyEvent;
use AnyEvent::Handle;
use AnyEvent::Socket;
use AnyEvent::Debug;
use JSON;

use Games::Construder::Protocol;
use Games::Construder::Server::Resources;
use Games::Construder::Server::Player;
use Games::Construder::Server::World;
use Games::Construder::Server::Objects;
use Games::Construder::Server::ChunkManager;
use Games::Construder::Vector;

use base qw/Object::Event/;

=head1 NAME

Games::Construder::Server - desc

=head1 SYNOPSIS

=head1 DESCRIPTION

=head1 METHODS

=over 4

=item my $obj = Games::Construder::Server->new (%args)

=cut

our $RES;
our $SHELL;

sub new {
   my $this  = shift;
   my $class = ref ($this) || $this;
   my $self  = { @_ };
   bless $self, $class;

   $self->init_object_events;

   $self->{port} ||= 9364;

   return $self
}

sub init {
   my ($self) = @_;

   $SHELL = AnyEvent::Debug::shell "unix/", "/tmp/construder_server_shell";
   if ($SHELL) {
      warn "started shell in /tmp/construder_server_shell, use with: 'socat readline /tmp/construder_server_shell'\n";
   }

   $RES = Games::Construder::Server::Resources->new;
   $RES->init_directories;
   $RES->load_region_file;
   $RES->load_world_gen_file;

   world_init ($self, $RES->{region_cmds});

   $RES->load_objects;
}

sub listen {
   my ($self) = @_;

   tcp_server undef, $self->{port}, sub {
      my ($fh, $h, $p) = @_;
      $self->{clids}++;
      my $cid = "$h:$p:$self->{clids}";
      my $hdl = AnyEvent::Handle->new (
         fh => $fh,
         on_error => sub {
            my ($hdl, $fatal, $msg) = @_;
            $hdl->destroy;
            $self->client_disconnected ($cid, "error: $msg");
         },
      );
      $self->{clients}->{$cid} = $hdl;
      $self->client_connected ($cid);
      $self->handle_protocol ($cid);
   };
}

sub handle_protocol {
   my ($self, $cid) = @_;

   $self->{clients}->{$cid}->push_read (packstring => "N", sub {
      my ($handle, $string) = @_;
      $self->handle_packet ($cid, data2packet ($string));
      $self->handle_protocol ($cid);
   }) if $self->{clients}->{$cid};
}

sub send_client {
   my ($self, $cid, $hdr, $body) = @_;
   $self->{clients}->{$cid}->push_write (packstring => "N", packet2data ($hdr, $body));
   if (!grep { $hdr->{cmd} eq $_ } qw/chunk activate_ui/) {
      warn "srv($cid)> $hdr->{cmd}\n";
   }
}

sub transfer_res2client {
   my ($self, $cid, $res) = @_;
   $self->{transfer}->{$cid} = [
      map {
         my $body = "";
         if (defined ${$_->[-1]} && not (ref ${$_->[-1]})) {
            $body = ${$_->[-1]};
            $_->[-1] = undef;
         } else {
            $_->[-1] = ${$_->[-1]};
         }
         warn "PREPARE RESOURCE $_->[0]: " . length ($body) . "\n";
         packet2data ({
            cmd => "resource",
            res => $_
         }, $body)
      } @$res
   ];
   $self->send_client ($cid, { cmd => "transfer_start" });
   $self->push_transfer ($cid);
}

sub push_transfer {
   my ($self, $cid) = @_;
   my $t = $self->{transfer}->{$cid};
   return unless $t;

   my $data = shift @$t;
   $self->{clients}->{$cid}->push_write (packstring => "N", $data);
   warn "srv($cid)trans(".length ($data).")\n";
   unless (@$t) {
      $self->send_client ($cid, { cmd => "transfer_end" });
      delete $self->{transfer}->{$cid};
   }
}

sub client_disconnected : event_cb {
   my ($self, $cid) = @_;
   my $pl = delete $self->{players}->{$cid};
   $pl->logout if $pl;
   delete $self->{player_guards}->{$cid};
   delete $self->{clients}->{$cid};
   warn "client disconnected: $cid\n";
}

sub players_near_pos {
   my ($self, $pos) = @_;
   my @p;
   for (values %{$self->{players}}) {
      my $d = vsub ($pos, $_->get_pos_normalized);
      if (vlength ($d) < 60) {
         push @p, $_;
      }
   }
   @p
}

sub client_connected : event_cb {
   my ($self, $cid) = @_;
}

sub handle_player_packet : event_cb {
   my ($self, $player, $hdr, $body) = @_;

   if ($hdr->{cmd} eq 'ui_response') {
      warn "UIRESPONSE @{$hdr->{pos}}\n";
      $player->ui_res ($hdr->{ui}, $hdr->{ui_command}, $hdr->{arg},
                       [$hdr->{pos}, $hdr->{build_pos}]);

   } elsif ($hdr->{cmd} eq 'player_pos') {
      $player->update_pos ($hdr->{pos}, $hdr->{look_vec});

   } elsif ($hdr->{cmd} eq 'visibility_radius') {
      $player->set_vis_rad ($hdr->{radius});

   } elsif ($hdr->{cmd} eq 'pos_action') {
      if ($hdr->{action} == 1 && @{$hdr->{build_pos} || []}) {
         $player->start_materialize ($hdr->{build_pos});

      } elsif ($hdr->{action} == 2 && @{$hdr->{build_pos} || []}) {
         $player->debug_at ($hdr->{pos});
         warn "build pos:\n";
         $player->debug_at ($hdr->{build_pos});

      } elsif ($hdr->{action} == 3 && @{$hdr->{pos} || []}) {
         $player->start_dematerialize ($hdr->{pos});
      }

   }

}

sub login {
   my ($self, $cid, $name) = @_;

   my $pl = $self->{players}->{$cid}
      = Games::Construder::Server::Player->new (
           cid => $cid, name => $name);

   $self->{player_guards}->{$cid} = $pl->reg_cb (send_client => sub {
      my ($pl, $hdr, $body) = @_;
      $self->send_client ($cid, $hdr, $body);
   });

   $pl->init;

   $self->send_client ($cid,
      { cmd => "login" });
}

sub handle_packet : event_cb {
   my ($self, $cid, $hdr, $body) = @_;

   if ($hdr->{cmd} ne 'player_pos') {
      warn "srv($cid)< $hdr->{cmd}\n";
   }

   if ($hdr->{cmd} eq 'hello') {
      $self->send_client ($cid,
         { cmd => "hello", version => "Games::Construder::Server 0.1" });

   } elsif ($hdr->{cmd} eq 'ui_response' && $hdr->{ui} eq 'login') {
      $self->send_client ($cid, { cmd => deactivate_ui => ui => "login" });

      if ($hdr->{ui_command} eq 'login') {
         $self->login ($cid, $hdr->{arg}->{name})
      }

   } elsif ($hdr->{cmd} eq 'login') {
      if ($hdr->{name} ne '') {
         $self->login ($cid, $hdr->{name})

      } else {
         $self->send_client ($cid, { cmd => activate_ui => ui => "login", desc => {
            window => { pos => [center => 'center'], },
            layout => [
               box => { dir => "vert", padding => 25 },
               [text => { align => 'center', font => 'big', color => "#00ff00" }, "Login"],
               [box => {  dir => "hor" },
                  [text => { font => 'normal', color => "#00ff00" }, "Name:"],
                  [entry => { font => 'normal', color => "#00ff00", arg => "name",
                              highlight => ["#111111", "#333333"], max_chars => 9 },
                   ""],
               ]
            ],
            commands => {
               default_keys => {
                  return => "login",
               },
            },
         } });
      }

   } elsif ($hdr->{cmd} eq 'transfer_poll') { # a bit crude :->
      $self->push_transfer ($cid);

   } elsif ($hdr->{cmd} eq 'list_resources') {
      my $res = $RES->list_resources;
      $self->send_client ($cid, { cmd => "resources_list", list => $res });

   } elsif ($hdr->{cmd} eq 'get_resources') {
      my $res = $RES->get_resources_by_id (@{$hdr->{ids}});
      $self->transfer_res2client ($cid, $res);

   } else {
      my $pl = $self->{players}->{$cid}
         or return;

      $self->handle_player_packet ($pl, $hdr, $body);
   }
}

=back

=head1 AUTHOR

Robin Redeker, C<< <elmex@ta-sa.org> >>

=head1 SEE ALSO

=head1 COPYRIGHT & LICENSE

Copyright 2011 Robin Redeker, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut

1;

