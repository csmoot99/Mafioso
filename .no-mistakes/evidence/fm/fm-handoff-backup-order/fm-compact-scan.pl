use JSON::PP;
my ($files,$comp,$fresh,$lower,$noafter)=(0,0,0,0,0);
for my $f (@ARGV){ open my $h,'<',$f or next; $files++; my ($pending,$before)=(0,undef); my $last;
 while(<$h>){ next unless /"token_count"|"compacted"/; my $d=eval{decode_json($_)} or next;
  if(($d->{type}//'') eq 'compacted'){ $comp++; $noafter++ if $pending; $pending=1; $before=$last; next }
  next unless ($d->{type}//'') eq 'event_msg' && ref $d->{payload} eq 'HASH' && ($d->{payload}{type}//'') eq 'token_count';
  my $i=$d->{payload}{info}; next unless ref $i eq 'HASH' && ref $i->{last_token_usage} eq 'HASH';
  my $u=$i->{last_token_usage}{total_tokens};
  if($pending){ $fresh++; $lower++ if defined $before && $u < $before; printf "%s before=%s after=%s window=%s\n", ($f=~m{([^/]+)$})[0], $before//'-', $u, $i->{model_context_window}; $pending=0 }
  $last=$u }
 $noafter++ if $pending }
print "files_with_compaction=$files compactions=$comp followed_by_token_count=$fresh fresh_lower_than_before=$lower no_token_count_after=$noafter\n";
