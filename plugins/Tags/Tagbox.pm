# This code is a part of Slash, and is released under the GPL.
# Copyright 1997-2005 by Open Source Technology Group. See README
# and COPYING for more information, or see http://slashcode.com/.

# The base class for all tagbox classes.  Each tagbox should be a
# direct subclass of Slash::Tagbox.

# This class's object creation methods are class methods:
#	new() - checks isInstalled() and calls getTagboxes(no_objects) to initialize $self
#	isInstalled() - self-evident
#	getTagboxes() - pulls in data from tagboxes table, returns it as base hash
#	DESTROY() - disconnect the dbh
#
# Its utility/convenience methods are these object methods:
#	getTagboxesNosyForGlobj()
#	userKeysNeedTagLog()
#	logDeactivatedTags()
#	logUserChange()
#	getMostImportantTagboxAffectedIDs()
#	addFeederInfo() - add a row to tagboxlog_feeder, later read by getMostImportantTagboxAffectedIDs()
#	forceFeederRecalc() - like addFeederInfo() but forced
#	markTagboxLogged
#	markTagboxRunComplete
#
# An important object method worth mentioning is:
#	getTagboxTags() - recursively fetches tags of interest to a tagbox;
#		designed to be generic enough for almost any tagbox
#
# These are the main four methods of the tagbox API:
#	feed_newtags() - more likely a subclass will override feed_newtags_process
#	feed_deactivatedtags()
#	feed_userchanges()
#	run()

package Slash::Tagbox;

use strict;
use Slash;
use Slash::Display;
use Apache::Cookie;

use base 'Slash::DB::Utility';
use base 'Slash::DB::MySQL';

use Data::Dumper;

our $VERSION = $Slash::Constants::VERSION;

# FRY: And where would a giant nerd be? THE LIBRARY!

#################################################################

sub isInstalled {
	my($class) = @_;
	my $constants = getCurrentStatic();
	return undef if !$constants->{plugin}{Tags};
	my($tagbox_name) = $class =~ /(\w+)$/;
	return undef if !$constants->{tagbox}{$tagbox_name};
	return 1;
}

sub init {
	my($self) = @_;
	$self->SUPER::init() if $self->can('SUPER::init');

	my %self_hash = %{ $self->getTagboxes($tagbox_name, undef, { no_objects => 1 }) };
	for my $key (keys %self_hash) {
		$self->{$key} = $self_hash{$key};
	}

	$self->init_tagfilters();
	1;
}

sub init_tagfilters {
	my($self) = @_;
	# by default, filter out nothing
}

#################################################################
#################################################################

# Return information about tagboxes, from the 'tagboxes' and
# 'tagbox_userkeyregexes' tables.
#
# If neither $id nor $field is specified, returns an arrayref of
# hashrefs, where each hashref has keys and values from the
# 'tagboxes' table, and additionally has the 'userkeyregexes' key
# with its value being an arrayref of (plain string) regexes from
# the tagbox_userkeyregexes.userkeyregex column.
#
# If $id is a true value, it must be a string, either the tbid or
# the name of a tagbox.  In this case only the hashref for that
# one tagbox's id is returned.
#
# If $field is a true value, it may be either a single string or
# an arrayref of strings.  In this case each hashref (or the one
# hashref) will have only the field(s) specified.  Requesting
# only the fields needed can have a very significant performance
# improvement (specifically, if the variant fields
# last_tagid_logged, last_userchange_logged, or last_run_completed
# are not needed, it will be much faster not to request them).

# This is a class method, not an object method.

{ # closure XXX this won't work with multiple sites, fix
my $tagboxes = undef;
sub getTagboxes {
	my($self, $id, $field, $options) = @_;
	my @fields = ( );
	if ($field) {
		@fields = ref($field) ? @$field : ($field);
	}
	my %fields = ( map { ($_, 1) } @fields );

	# Update the data to current if necessary;  load it all if necessary.
	if ($tagboxes) {
		# The data in these four columns is never cached.  Only load it
		# from the DB if it is requested (i.e. if $field was empty so
		# all fields are needed, or if $field is an array with any).
		if (!@fields
			|| $fields{last_run_completed}
			|| $fields{last_tagid_logged}
			|| $fields{last_tdid_logged}
			|| $fields{last_tuid_logged}
		) {
			my $new_hr = $self->sqlSelectAllHashref('tbid',
				'tbid, last_run_completed,
				 last_tagid_logged, last_tdid_logged, last_tuid_logged',
				'tagboxes');
			for my $hr (@$tagboxes) {
				$hr->{last_run_completed} = $new_hr->{$hr->{tbid}}{last_run_completed};
				$hr->{last_tagid_logged}  = $new_hr->{$hr->{tbid}}{last_tagid_logged};
				$hr->{last_tuid_logged}   = $new_hr->{$hr->{tbid}}{last_tuid_logged};
				$hr->{last_tdid_logged}   = $new_hr->{$hr->{tbid}}{last_tdid_logged};
			}
		}
	} else {
		$tagboxes = $self->sqlSelectAllHashrefArray('*', 'tagboxes', '', 'ORDER BY tbid');
		my $regex_ar = $self->sqlSelectAllHashrefArray('name, userkeyregex',
			'tagbox_userkeyregexes',
			'', 'ORDER BY name, userkeyregex');
		for my $hr (@$tagboxes) {
			$hr->{userkeyregexes} = [
				map { $_->{userkeyregex} }
				grep { $_->{name} eq $hr->{name} }
				@$regex_ar
			];
		}
		# the getObject() below calls new() on each tagbox class,
		# which calls getTagboxes() with no_objects set.
		if (!$options->{no_objects}) {
			for my $hr (@$tagboxes) {
				my $object = getObject("Slash::Tagbox::$hr->{name}");
				$hr->{object} = $object;
			}
			# If any object failed to be created for some reason,
			# that tagbox never gets returned.
			$tagboxes = [ grep { $_->{object} } @$tagboxes ];
		}
	}

	# If one or more fields were asked for, then some of the
	# data in the other fields may not be current since we
	# may have skipped loading the last_* fields.  Make a
	# copy of the data so the $tagboxes closure is not
	# affected, then delete all but the fields requested
	# (returning stale data could lead to nasty bugs).
	my $tb = [ @$tagboxes ];

	# If just one specific tagbox was requested, take out all the
	# others.
	if ($id) {
		my @tb_tmp;
		if ($id =~ /^\d+$/) {
			@tb_tmp = grep { $_->{tbid} == $id } @$tb;
		} else {
			@tb_tmp = grep { $_->{name} eq $id } @$tb;
		}
		return undef if !@tb_tmp;
		$tb = [ $tb_tmp[0] ];
	}

	# Clone the data so we don't affect the $tagboxes persistent
	# closure variable.
	my $tbc = [ ];
	for my $tagbox (@$tb) {
		my %tagbox_hash = %$tagbox;
		push @$tbc, \%tagbox_hash;
	}

	# If specific fields were requested, go through the data
	# and strip out the fields that were not requested.
	if (@fields) {
		for my $tagbox (@$tbc) {
			my @stale = grep { !$fields{$_} } keys %$tagbox;
			delete @$tagbox{@stale};
		}
	}

	# If one specific tagbox was requested, return its hashref.
	# Otherwise return an arrayref of all their hashrefs.
	return $tbc->[0] if $id;
	return $tbc;
}
}

# Cache a list of which gtids map to which tagboxes, so we can quickly
# return a list of tagboxes that want a "nosy" entry for a given gtid.
# Input is a hashref with the globj fields (the only one this cares
# about at the moment is gtid, but that may change in future).  Output
# is an array of tagbox IDs.

{ # closure XXX this won't work with multiple sites, fix
my $gtid_to_tbids = { };
sub getTagboxesNosyForGlobj {
	my($self, $globj_hr) = @_;
	my $gtid;
	if (!keys %$gtid_to_tbids) {
		my $globj_types = $self->getGlobjTypes();
		for $gtid (grep /^\d+$/, keys %$globj_types) {
			$gtid_to_tbids->{ $gtid } = [ ];
		}
		my $tagboxes = $self->getTagboxes();
		for my $tb_hr (@$tagboxes) {
			my @nosy = grep /^\d+$/, split / /, $tb_hr->{nosy_gtids};
			for $gtid (@nosy) {
				push @{ $gtid_to_tbids->{$gtid} }, $tb_hr->{tbid};
			}
		}
	}
	$gtid = $globj_hr->{gtid};
	return @{ $gtid_to_tbids->{$gtid} };
}
}

{ # closure XXX this won't work with multiple sites, fix
my $userkey_masterregex;
sub userKeysNeedTagLog {
	my($self, $keys_ar) = @_;

	if (!defined $userkey_masterregex) {
		my $tagboxes = $self->getTagboxes();
		my @regexes = ( );
		for my $tagbox (@$tagboxes) {
			for my $regex (@{$tagbox->{userkeyregexes}}) {
				push @regexes, $regex;
			}
		}
		if (@regexes) {
			my $r = '(' . join('|', map { "($_)" } @regexes) . ')';
			$userkey_masterregex = qr{$r};
		} else {
			$userkey_masterregex = '';
		}
	}

	# If no tagboxes have regexes, nothing can match.
	return if !$userkey_masterregex;

	my @update_keys = ( );
	for my $k (@$keys_ar) {
		push @update_keys, $k if $k =~ $userkey_masterregex;
	}
	return @update_keys;
}
}

sub logDeactivatedTags {
	my($self, $deactivated_tagids) = @_;
	return 0 if !$deactivated_tagids;
	my $logged = 0;
	for my $tagid (@$deactivated_tagids) {
		$logged += $self->sqlInsert('tags_deactivated',
			{ tagid => $tagid });
	}
	return $logged;
}

sub logUserChange {
	my($self, $uid, $name, $old, $new) = @_;
	return $self->sqlInsert('tags_userchange', {
		-created_at =>	'NOW()',
		uid =>		$uid,
		user_key =>	$name,
		value_old =>	$old,
		value_new =>	$new,
	});
}

sub getMostImportantTagboxAffectedIDs {
	my($self, $num, $min_weightsum) = @_;
	$num ||= 10;
	$min_weightsum ||= 1;
	return $self->sqlSelectAllHashrefArray(
		'tagboxes.tbid,
		 affected_id,
		 MAX(tfid) AS max_tfid,
		 SUM(importance*weight) AS sum_imp_weight',
		'tagboxes, tagboxlog_feeder',
		'tagboxes.tbid=tagboxlog_feeder.tbid',
		"GROUP BY tagboxes.tbid, affected_id
		 HAVING sum_imp_weight >= $min_weightsum
		 ORDER BY sum_imp_weight DESC LIMIT $num");
}

sub getTagboxTags {
	my($self, $tbid, $affected_id, $extra_levels, $options) = @_;
	warn "no tbid for $self" if !$tbid;
	$extra_levels ||= 0;
	my $type = $options->{type} || $self->getTagboxes($tbid, 'affected_type')->{affected_type};
	$self->debugLog("getTagboxTags(%d, %d, %d), type=%s",
		$tbid, $affected_id, $extra_levels, $type);
	my $hr_ar = [ ];
	my $colname = ($type eq 'user') ? 'uid' : 'globjid';
	my $max_time_clause = '';
	if ($options->{max_time_noquote}) {
		$max_time_clause = " AND created_at <= $options->{max_time_noquote}";
	} elsif ($options->{max_time}) {
		my $mtq = $self->sqlQuote($options->{max_time});
		$max_time_clause = " AND created_at <= $mtq";
	}
	$hr_ar = $self->sqlSelectAllHashrefArray(
		'*, UNIX_TIMESTAMP(created_at) AS created_at_ut',
		'tags',
		"$colname=$affected_id $max_time_clause",
		'ORDER BY tagid');
	$self->debugLog("colname=%s pre_filter hr_ar=%d",
		$colname, scalar(@$hr_ar));
	$hr_ar = $self->feed_newtags_filter($hr_ar);
	$self->debugLog("colname=%s post_filter hr_ar=%d",
		$colname, scalar(@$hr_ar));

	# If extra_levels were requested, fetch them.  
	my $old_colname = $colname;
	while ($extra_levels) {
		$self->debugLog("el %d", $extra_levels);
		my $new_colname = ($old_colname eq 'uid') ? 'globjid' : 'uid';
		my %new_ids = ( map { ($_->{$new_colname}, 1) } @$hr_ar );
		my $new_ids = join(',', sort { $a <=> $b } keys %new_ids);
		$self->debugLog("hr_ar=%d with %s=%s",
			scalar(@$hr_ar), $colname, $affected_id);
		$hr_ar = $self->sqlSelectAllHashrefArray(
			'*, UNIX_TIMESTAMP(created_at) AS created_at_ut',
			'tags',
			"$new_colname IN ($new_ids) $max_time_clause",
			'ORDER BY tagid');
		$self->debugLog("new_colname=%s pre_filter hr_ar=%d",
			$new_colname, scalar(@$hr_ar));
		$hr_ar = $self->feed_newtags_filter($hr_ar);
		$self->debugLog("new_colname=%s new_ids=%d (%.20s) hr_ar=%d",
			$new_colname, scalar(keys %new_ids), $new_ids, scalar(@$hr_ar));
		$old_colname = $new_colname;
		--$extra_levels;
		$self->debugLog("el %d", $extra_levels);
	}
	$self->addGlobjEssentialsToHashrefArray($hr_ar);
	return $hr_ar;
}

sub addFeederInfo {
	my($self, $tbid, $info_hr) = @_;
	$info_hr->{-created_at} = 'NOW()';
	$info_hr->{tbid} = $tbid;
	return $self->sqlInsert('tagboxlog_feeder', $info_hr);
}

sub forceFeederRecalc {
	my($self, $tbid, $affected_id) = @_;
	my $info_hr = {
		-created_at =>	'NOW()',
		tbid =>		$tbid,
		affected_id =>	$affected_id,
		importance =>	999999,
		tagid =>	undef,
		tdid =>		undef,
		tuid =>		undef,
	};
	return $self->sqlInsert('tagboxlog_feeder', $info_hr);
}

sub markTagboxLogged {
	my($self, $tbid, $update_hr) = @_;
	$self->sqlUpdate('tagboxes', $update_hr, "tbid=$tbid");
}

sub markTagboxRunComplete {
	my($self, $affected_hr) = @_;

	my $delete_clause = "tbid=$affected_hr->{tbid} AND affected_id=$affected_hr->{affected_id}";
	$delete_clause .= " AND tfid <= $affected_hr->{max_tfid}";

	$self->sqlDelete('tagboxlog_feeder', $delete_clause);
	$self->sqlUpdate('tagboxes',
		{ -last_run_completed => 'NOW()' },
		"tbid=$affected_hr->{tbid}");
}

sub info_log {
	my($self, $format, @args) = @_;
	my $caller = join ',', (caller(1))[3,4];
	main::tagboxLog("%s $format", $caller, @args);
}

sub debug_log {
	my($self, $format, @args) = @_;
	if ($self->{debug} > 0) {
		my $caller = join ',', (caller(1))[3,4];
		main::tagboxLog("%s $format", $caller, @args);
	}
}

#################################################################
#################################################################

sub feed_newtags {
	my($self, $tags_ar) = @_;
	$tags_ar = $self->feed_newtags_filter($tags_ar);
	$self->feed_newtags_pre($tags_ar);

	my $ret_ar = $self->feed_newtags_process($tags_ar);

	$self->feed_newtags_post($ret_ar);
	return $ret_ar;
}

sub feed_newtags_filter {
	my($self, $tags_ar) = @_;

	# If the tagbox wants only still-active tags, eliminate any
	# inactivated tags.
	if ($self->{filter_activeonly}) {
		$tags_ar = [ grep { $_->{inactivated} } @$tags_ar ];
	}

	# If a tagnameid filter is in place, eliminate any tags with
	# tagnames not on the list.
	if ($self->{filter_tagnameid}) {
		my $tagnameid_ar = ref($self->{filter_tagnameid})
			? $self->{filter_tagnameid} : [ $self->{filter_tagnameid} ];
		my %tagnameid_wanted = ( map { ($_, 1) } @$tagnameid_ar );
		$tags_ar = [ grep { $tagnameid_wanted{ $_->{tagnameid} } } @$tags_ar ];
	}

	# If a gtid filter is in place, eliminate any tags on globjs
	# not of those type(s).
	if ($self->{filter_gtid}) {
		my $gtid_ar = ref($self->{filter_gtid})
			? $self->{filter_gtid} : [ $self->{filter_gtid} ];
		my $all_gtid_str = join(',', sort { $a <=> $b } @$gtid_ar);
		my %all_globjids = ( map { ($_->{globjid}, 1) } @$tags_ar );
		my $all_globjids_str = join(',', sort { $a <=> $b } keys %all_globjids);
		if ($all_gtid_str && $all_globjids_str) {
			my $globjids_wanted_ar = $self->sqlSelectColArrayref(
				'globjid',
				'globjs',
				"globjid IN ($all_globjids_str)
				 AND gtid IN ($all_gtid_str)");
			my %globjid_wanted = ( map { ($_, 1) } @$globjids_wanted_ar );
			$tags_ar = [ grep { $globjid_wanted{ $_->{globjid} } } @$tags_ar ];
		} else {
			$tags_ar = [ ];
		}
	}

	return $tags_ar;
}

sub feed_newtags_pre {
	my($self, $tags_ar) = @_;
	# XXX only if debugging is on
	# XXX note in log here, instead of feed_d_pre, if tdid's present
	my $count = scalar(@$tags_ar);
	if ($count < 9) {
		$self->infoLog("filtered tags '%s'",
			 join(' ', map { $_->{tagid} } @$tags_ar));
	} else {
		$self->infoLog("%d filtered tags '%s ... %s'",
			scalar(@$tags_ar), $tags_ar->[0]{tagid}, $tags_ar->[-1]{tagid});
	}
}

sub feed_newtags_post {
	my($self, $ret_ar) = @_;
	# XXX only if debugging is on
	$self->infoLog("returning %d", scalar(@$ret_ar));
}

sub feed_newtags_process {
	my($self, $tags_ar) = @_;
	# by default, add importance of 1 for each tag that made it through filtering
	my $ret_ar = [ ];
	for my $tag_hr (@$tags_ar) {
		my $ret_hr = {
			affected_id =>  $tag_hr->{globjid},
			importance =>   1,
		};
		# Both new tags and deactivated tags are considered important.
		# Pass along either the tdid or the tagid field, depending on
		# which type each hashref indicates.
		if ($tag_hr->{tdid})    { $ret_hr->{tdid}  = $tag_hr->{tdid}  }
		else                    { $ret_hr->{tagid} = $tag_hr->{tagid} }
		push @$ret_ar, $ret_hr;
	}
	return $ret_ar;
}

#################################################################

sub feed_deactivatedtags {
	my($self, $tags_ar) = @_;
	$self->feed_deactivatedtags_pre($tags_ar);

	# by default, just pass along to feed_newtags (which will have to
	# check $tags_ar->[]{tdid} to determine whether the changes were
	# really new tags or just deactivated tags)
	return $self->feed_newtags($tags_ar);
}

sub feed_deactivatedtags_pre {
	my($self, $tags_ar) = @_;
	main::tagboxLog("$self->{name}->feed_deactivatedtags called: tags_ar='"
		. join(' ', map { $_->{tagid} } @$tags_ar) .  "'");
}

#################################################################

sub feed_userchanges {
	my($self, $users_ar) = @_;
	$self->feed_userchanges_pre($users_ar);

	# by default, do not care about any user changes
	return [ ];
}

sub feed_userchanges_pre {
	my($self, $users_ar) = @_;
	main::tagboxLog("$self->{name}->feed_userchanges called: users_ar='"
		. join(' ', map { $_->{tuid} } @$users_ar) .  "'");
}

#################################################################

sub run {
	my($self, $affected_id) = @_;
	warn "Slash::Tagbox::run($affected_id) not overridden, called for $self";
	return undef;
}

#################################################################
#################################################################

sub DESTROY {
	my($self) = @_;
	$self->{_dbh}->disconnect if $self->{_dbh} && !$ENV{GATEWAY_INTERFACE};
	$self->SUPER::DESTROY if $self->can("SUPER::DESTROY");
}

1;

=head1 NAME

Slash::Tagbox - Slash Tagbox module

=head1 SYNOPSIS

	use Slash::Tagbox;

=head1 DESCRIPTION

This contains all of the routines currently used by Tagbox.

=head1 SEE ALSO

Slash(3).

=cut

