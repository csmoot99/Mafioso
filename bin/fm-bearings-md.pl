#!/usr/bin/env perl
# fm-bearings-md.pl - render one untrusted markdown report as an inert HTML page.
#
# Usage: fm-bearings-md.pl <report.md> [download-name.md]   (HTML page on stdout)
#        fm-bearings-md.pl --text <report.md>               (plain-text search index on stdout)
#
# Owned by bin/fm-bearings-board.sh, which publishes the result beside the
# /bearings lavish board. The report text is written by workers, so the page is
# inert by construction: every character of the source is HTML-escaped before
# any markup is added, so the only tags in the output are the ones this script
# writes; the page carries no script and no remote reference, and a CSP meta
# denies everything but its own inline style as a second layer. Links are kept
# only for http(s) addresses and open in a new tab; images render as their alt
# text and are never fetched.
#
# Covered markdown: headings, paragraphs, bullet and numbered lists (nested,
# with task boxes), tables, fenced and inline code, block quotes, rules, links,
# bold, italics and strike-through. Anything else shows as plain escaped text.
use strict;
use warnings;
use utf8;
no warnings 'utf8';

use MIME::Base64 ();

my $text_mode = @ARGV && $ARGV[0] eq '--text' ? shift(@ARGV) : 0;
my ($file, $dlname) = @ARGV;
defined $file && @ARGV <= 2 or die "usage: fm-bearings-md.pl <report.md> [download-name.md]\n";
$dlname = 'report.md' unless defined $dlname && $dlname =~ /\A[A-Za-z0-9._-]+\z/;
my $raw = do {
    open(my $rh, '<:raw', $file) or die "fm-bearings-md: cannot read $file\n";
    local $/;
    my $c = <$rh>;
    defined $c ? $c : '';
};
if ($text_mode) {
    # one line of words for board search: markdown marks dropped, whitespace collapsed
    my $t = do { open(my $th, '<:encoding(UTF-8)', $file) or die "fm-bearings-md: cannot read $file\n"; local $/; <$th> // '' };
    $t =~ s/\A\x{FEFF}//;
    $t =~ s/[\x00-\x1F\x7F]+/ /g;
    $t =~ s/!?\[([^\]]*)\]\([^)]*\)/$1/g;
    $t =~ s/[`*_~#>|]+/ /g;
    $t =~ s/\s+/ /g;
    $t =~ s/^ | $//g;
    binmode(STDOUT, ':encoding(UTF-8)');
    print $t;
    exit 0;
}
my $b64 = MIME::Base64::encode_base64($raw, '');

my $src = do {
    open(my $fh, '<:encoding(UTF-8)', $file) or die "fm-bearings-md: cannot read $file\n";
    local $/;
    my $c = <$fh>;
    defined $c ? $c : '';
};
$src =~ s/\r\n?/\n/g;
$src =~ s/\t/    /g;
$src =~ s/[\x00-\x08\x0B-\x1F\x7F]//g;
$src =~ s/\A\x{FEFF}//;

sub esc {
    my ($s) = @_;
    $s =~ s/&/&amp;/g;
    $s =~ s/</&lt;/g;
    $s =~ s/>/&gt;/g;
    $s =~ s/"/&quot;/g;
    $s =~ s/'/&#39;/g;
    return $s;
}

# Inline spans. Code, images and links are lifted into placeholders first (their
# text is escaped as it is lifted), then the rest is escaped and emphasised.
sub inline {
    my ($t) = @_;
    my @hold;
    my $lift = sub { push @hold, $_[0]; return "\x00" . $#hold . "\x00" };
    $t =~ s/(`+)(.+?)\1/$lift->('<code>' . esc($2) . '<\/code>')/ge;
    $t =~ s/!\[([^\]]*)\]\([^)\s]*(?:\s+"[^"]*")?\)/$lift->(esc($1))/ge;
    $t =~ s{\[([^\]]+)\]\((https?://[^)\s]+)(?:\s+"[^"]*")?\)}{
        $lift->('<a href="' . esc($2) . '" target="_blank" rel="noopener noreferrer">' . esc($1) . '</a>')
    }ge;
    $t =~ s{<(https?://[^>\s]+)>}{
        $lift->('<a href="' . esc($1) . '" target="_blank" rel="noopener noreferrer">' . esc($1) . '</a>')
    }ge;
    $t =~ s{(?<![\w"=/])(https?://[^\s<>\x00]+)}{
        my $u = $1;
        my $tail = $u =~ s/([.,;:!?)\]'"*_]+)\z// ? $1 : '';
        $lift->('<a href="' . esc($u) . '" target="_blank" rel="noopener noreferrer">' . esc($u) . '</a>') . $tail
    }ge;
    $t = esc($t);
    $t =~ s/\*\*(?=\S)(.+?)(?<=\S)\*\*/<strong>$1<\/strong>/g;
    $t =~ s/(?<![\w_])__(?=\S)(.+?)(?<=\S)__(?![\w_])/<strong>$1<\/strong>/g;
    $t =~ s/(?<![\w*])\*(?=[^\s*])(.+?)(?<=[^\s*])\*(?![\w*])/<em>$1<\/em>/g;
    $t =~ s/(?<![\w_])_(?=[^\s_])(.+?)(?<=[^\s_])_(?![\w_])/<em>$1<\/em>/g;
    $t =~ s/~~(?=\S)(.+?)(?<=\S)~~/<del>$1<\/del>/g;
    $t =~ s/\x00(\d+)\x00/$hold[$1]/g;
    return $t;
}

my $LIST_RE  = qr/^(\s*)([-*+]|\d{1,9}[.)])\s+(.*)$/;
my $RULE_RE  = qr/^\s{0,3}([-*_])(?:\s*\1){2,}\s*$/;
my $FENCE_RE = qr/^\s*(`{3,}|~{3,})/;
my $TSEP_RE  = qr/^\s*\|?\s*:?-+:?\s*(?:\|\s*:?-+:?\s*)*\|?\s*$/;

sub cells {
    my ($l) = @_;
    $l =~ s/^\s*\|//;
    $l =~ s/\|\s*$//;
    my @c = split(/(?<!\\)\|/, $l, -1);
    return map { my $x = $_; $x =~ s/^\s+|\s+$//g; $x =~ s/\\\|/|/g; $x } @c;
}

sub starts_block {
    my ($l, $next) = @_;
    return 1 if $l =~ /^\s{0,3}#{1,6}\s/ || $l =~ $FENCE_RE || $l =~ $RULE_RE
        || $l =~ /^\s{0,3}>/ || $l =~ $LIST_RE;
    return 1 if $l =~ /\|/ && defined $next && $next =~ /\|/ && $next =~ $TSEP_RE && $next =~ /-/;
    return 0;
}

sub list_block {
    my ($lines, $i, $depth) = @_;
    $lines->[$$i] =~ $LIST_RE;
    my ($base, $marker) = (length($1), $2);
    my $tag = $marker =~ /^\d/ ? 'ol' : 'ul';
    my $out = "<$tag>";
    while ($$i < @$lines && $lines->[$$i] =~ $LIST_RE) {
        my ($ind, $mark, $body) = (length($1), $2, $3);
        last unless $ind == $base && ($mark =~ /^\d/ ? 'ol' : 'ul') eq $tag;
        $$i++;
        my $box = '';
        if ($body =~ s/^\[( |x|X)\]\s+//) { $box = $1 eq ' ' ? "\x{2610} " : "\x{2611} " }
        my $item = $box . inline($body);
        my $nested = '';
        while ($$i < @$lines) {
            my $l = $lines->[$$i];
            if ($l =~ /^\s*$/) {
                my $j = $$i;
                $j++ while $j < @$lines && $lines->[$j] =~ /^\s*$/;
                last unless $j < @$lines && $lines->[$j] =~ /^(\s*)\S/ && length($1) > $base;
                $$i = $j;
                next;
            }
            $l =~ /^(\s*)/;
            last unless length($1) > $base;
            if ($l =~ $LIST_RE) {
                last if $depth >= 6;
                $nested .= list_block($lines, $i, $depth + 1);
            } else {
                $l =~ s/^\s+//;
                $item .= ' ' . inline($l);
                $$i++;
            }
        }
        $out .= "<li>$item$nested</li>";
    }
    return "$out</$tag>";
}

sub blocks {
    my ($lines, $depth) = @_;
    my ($i, $out) = (0, '');
    while ($i < @$lines) {
        my $l = $lines->[$i];
        if ($l =~ /^\s*$/) { $i++; next }
        if ($l =~ $FENCE_RE) {
            my $fence = $1;
            my $ch = substr($fence, 0, 1);
            my $close = qr/^\s*\Q$ch\E{@{[length $fence]},}\s*$/;
            $i++;
            my @code;
            while ($i < @$lines && $lines->[$i] !~ $close) { push @code, $lines->[$i++] }
            $i++;
            $out .= '<pre><code>' . esc(join("\n", @code)) . '</code></pre>';
            next;
        }
        if ($l =~ /^\s{0,3}(#{1,6})\s+(.*?)\s*#*\s*$/) {
            my $n = length($1);
            $out .= "<h$n>" . inline($2) . "</h$n>";
            $i++;
            next;
        }
        if ($l =~ $RULE_RE) { $out .= '<hr>'; $i++; next }
        if ($l =~ /\|/ && $i + 1 < @$lines && $lines->[$i + 1] =~ /\|/
            && $lines->[$i + 1] =~ $TSEP_RE && $lines->[$i + 1] =~ /-/) {
            my @head = cells($l);
            $i += 2;
            my $rows = '';
            while ($i < @$lines && $lines->[$i] =~ /\|/ && $lines->[$i] !~ /^\s*$/) {
                $rows .= '<tr>' . join('', map { '<td>' . inline($_) . '</td>' } cells($lines->[$i])) . '</tr>';
                $i++;
            }
            $out .= '<div class="tw"><table><thead><tr>'
                . join('', map { '<th>' . inline($_) . '</th>' } @head)
                . "</tr></thead><tbody>$rows</tbody></table></div>";
            next;
        }
        if ($l =~ /^\s{0,3}>/) {
            my @q;
            while ($i < @$lines && $lines->[$i] =~ /^\s{0,3}>\s?(.*)$/) { push @q, $1; $i++ }
            $out .= '<blockquote>' . ($depth < 4 ? blocks(\@q, $depth + 1) : esc(join(' ', @q))) . '</blockquote>';
            next;
        }
        if ($l =~ $LIST_RE) { $out .= list_block($lines, \$i, 0); next }
        my @p = ($l);
        $i++;
        while ($i < @$lines && $lines->[$i] !~ /^\s*$/ && !starts_block($lines->[$i], $lines->[$i + 1])) {
            push @p, $lines->[$i++];
        }
        s/^\s+|\s+$//g for @p;
        $out .= '<p>' . inline(join("\n", @p)) . '</p>';
    }
    return $out;
}

my $body = blocks([split(/\n/, $src, -1)], 0);
$body = '<p class="empty">This report is empty.</p>' if $body eq '';

binmode(STDOUT, ':encoding(UTF-8)');
print <<"HTML";
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
<meta name="referrer" content="no-referrer">
<title>Report</title>
<style>
:root { --paper-000:#fbf4e2; --paper-100:#f6ecd3; --paper-200:#f0e3c4; --line:#ddc89c; --soft:#e7d6ae;
  --ink-900:#241c14; --ink-700:#3f3224; --ink-500:#6f5e46; --rust-500:#c0452a; --ocean-600:#2f6688; }
* { box-sizing: border-box; }
html { -webkit-text-size-adjust: 100%; }
body { margin: 0; padding: 18px 16px 56px; background: var(--paper-100); color: var(--ink-700);
  font: 16px/1.6 ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
  overflow-wrap: anywhere; }
main { max-width: 760px; margin: 0 auto; }
h1, h2, h3, h4, h5, h6 { color: var(--ink-900); line-height: 1.25; margin: 1.5em 0 0.5em; }
h1 { font-size: 1.55rem; margin-top: 0; } h2 { font-size: 1.3rem; } h3 { font-size: 1.12rem; }
h4, h5, h6 { font-size: 1rem; }
p, ul, ol, blockquote, pre, .tw { margin: 0 0 1em; }
ul, ol { padding-left: 1.4em; } li { margin: 0.2em 0; } li > ul, li > ol { margin: 0.2em 0 0; }
a { color: var(--ocean-600); text-decoration: underline; }
code { font: 0.875em ui-monospace, "SF Mono", Menlo, Consolas, monospace; background: var(--paper-200);
  border: 1px solid var(--soft); border-radius: 4px; padding: 0.05em 0.3em; }
pre { background: var(--paper-000); border: 1px solid var(--line); border-radius: 9px; padding: 12px 14px; overflow-x: auto; }
pre code { background: none; border: 0; padding: 0; font-size: 0.8125rem; line-height: 1.5; }
blockquote { border-left: 3px solid var(--rust-500); background: var(--paper-000); color: var(--ink-500);
  padding: 0.4em 0.9em; border-radius: 0 9px 9px 0; }
blockquote > :last-child { margin-bottom: 0; }
hr { border: 0; border-top: 1px solid var(--line); margin: 1.5em 0; }
.tw { overflow-x: auto; }
table { border-collapse: collapse; font-size: 0.875rem; min-width: 100%; }
th, td { border: 1px solid var(--line); padding: 6px 10px; text-align: left; vertical-align: top; }
th { background: var(--paper-200); color: var(--ink-900); }
.empty { color: var(--ink-500); }
.dl { display: flex; justify-content: flex-end; max-width: 760px; margin: 0 auto 14px; }
.dl a { display: inline-flex; align-items: center; min-height: 44px; padding: 8px 16px; border-radius: 9px;
  background: var(--ink-900); color: var(--paper-000); font-weight: 700; font-size: 0.9375rem; text-decoration: none; }
\@media (max-width: 640px) { pre { white-space: pre-wrap; overflow-wrap: anywhere; } }
</style>
</head>
<body>
<div class="dl"><a download="$dlname" href="data:text/markdown;charset=utf-8;base64,$b64">Download report (.md)</a></div>
<main>
$body
</main></body>
</html>
HTML
