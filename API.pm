package Plugins::MusicArtistInfo::API;

use strict;
use Digest::SHA1 qw(sha1_base64);
use URI;
use URI::Escape qw(uri_escape_utf8);
use URI::QueryParam;

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

use constant BASE_URL => 'https://api.lms-community.org/music';
# use constant BASE_URL => 'http://127.0.0.1:8787/music';
use constant ARTISTIMAGESEARCH_URL => BASE_URL . '/artist/%s/picture';
use constant ALBUMREVIEW_URL => BASE_URL . '/album/%s/%s/review';
use constant TRACKREVIEW_URL => BASE_URL . '/track/%s/%s/review';
use constant LYRICS_URL      => BASE_URL . '/track/%s/%s/lyrics';
use constant ALBUMGENRES_URL => BASE_URL . '/album/%s/%s/genres';
use constant BIOGRAPHY_URL   => BASE_URL . '/artist/%s/biography';
use constant WORKREVIEW_URL  => BASE_URL . '/work/%s/%s/review';
use constant LYRICS_PROVIDERS_URL => BASE_URL . '/metadata/lyricsProviders';
use constant KILLWORDS_URL   => BASE_URL . '/metadata/killwords';

use constant PLUGIN_PACKAGE => __PACKAGE__ =~ s/\b(?:\w+)$/Plugin/r;

my $cache = Slim::Utils::Cache->new();
my $log = logger('plugin.musicartistinfo');
my $prefs = preferences('plugin.musicartistinfo');
my $serverPrefs = preferences('server');

my $xMAICfgString;
my $version;
my $hitRateLimit;

my %queryQueue;

if (!main::SCANNER) {
	$prefs->setChange(sub { _initXMAICfgString(1) },
		'browseArtistPictures',
		'lookupArtistPictures',
		'lookupAlbumArtistPicturesOnly',
		'artistImageFolder',
		'saveMissingArtistPicturePlaceholder'
	);

	$serverPrefs->setChange(sub { _initXMAICfgString(1) },
		'precacheArtwork',
	);
}

sub getArtistPhoto {
	my ( $class, $cb, $args ) = @_;

	my $query = _getArtistQueryParams($args);
	my $artist = Plugins::MusicArtistInfo::Common::normalizeArtistName($args->{artist});
	my $url = sprintf(ARTISTIMAGESEARCH_URL, uri_escape_utf8($artist)) . $query;
	my $cacheKey = "mai_artist_artwork_$url";

	my $cached = $cache->get($cacheKey);
	if (defined $cached) {
		main::INFOLOG && $log->is_info && $log->info("Using cached artist picture: $cached");
		return $cb->({ url => $cached });
	}

	_call(
		$url,
		sub {
			my ($result) = @_;

			my $photo;

			if ($result && ref $result && (my $url = $result->{picture})) {
				$photo = {
					url => $url,
				};
			}

			$cache->set($cacheKey, $photo->{url}, '1y') if $photo->{url};

			main::INFOLOG && $log->is_info && $log->info(Data::Dump::dump($photo));

			$cb->($photo);
		}
	);
}

sub getArtistBioId {
	my ( $class, $cb, $args ) = @_;

	my $query = _getArtistQueryParams($args);
	my $url = sprintf(BIOGRAPHY_URL, uri_escape_utf8($args->{artist})) . $query;

	_call(
		$url,
		sub {
			my ($result) = @_;

			main::INFOLOG && $log->is_info && $log->info("found biography: " . Data::Dump::dump($result));

			$cb->($result);
		}
	);
}

sub _getArtistQueryParams {
	my $args = shift;

	my @queryParams;
	push @queryParams, 'mbid=' . $args->{mbid} if $args->{mbid};
	push @queryParams, 'lang=' . $args->{lang} if $args->{lang};
	# the album name in the artists related queries is used to better disambiguate artists with common names, so include it if available
	push @queryParams, 'album=' . uri_escape_utf8($args->{album}) if $args->{album};

	return @queryParams ? '?' . join('&', @queryParams) : '';
}

sub getAlbumReviewId {
	my ( $class, $cb, $args ) = @_;

	my $url = _prepareAlbumUrl(ALBUMREVIEW_URL, $args);

	_call(
		$url,
		sub {
			my ($result) = @_;

			main::INFOLOG && $log->is_info && $log->info("found album review: " . Data::Dump::dump($result));

			$cb->($result);
		}
	);
}

sub getTrackReviewId {
	my ( $class, $cb, $args ) = @_;

	my @queryParams;
	push @queryParams, 'mbid=' . $args->{mbid} if $args->{mbid};
	push @queryParams, 'lang=' . $args->{lang} if $args->{lang};

	my $query = @queryParams ? '?' . join('&', @queryParams) : '';

	my $url = sprintf(TRACKREVIEW_URL, uri_escape_utf8($args->{title}), uri_escape_utf8($args->{artist})) . $query;

	_call(
		$url,
		sub {
			my ($result) = @_;

			main::INFOLOG && $log->is_info && $log->info("found track review: " . Data::Dump::dump($result));

			$cb->($result);
		},{
			radioUrl => $args->{radioUrl},
		}
	);
}

sub getAlbumGenres {
	my ( $class, $cb, $args ) = @_;

	my $url = _prepareAlbumUrl(ALBUMGENRES_URL, $args);

	_call(
		$url,
		sub {
			my ($result) = @_;

			main::INFOLOG && $log->is_info && $log->info("found album genres: " . Data::Dump::dump($result));

			$cb->($result);
		}
	);
}

sub getWorkReviewId {
	my ( $class, $cb, $args ) = @_;

	my $url = sprintf(WORKREVIEW_URL, uri_escape_utf8($args->{title}), uri_escape_utf8($args->{composer}));
	$url .= '?lang=' . $args->{lang} if $args->{lang};

	_call(
		$url,
		sub {
			my ($result) = @_;

			main::INFOLOG && $log->is_info && $log->info("found work review: " . Data::Dump::dump($result));

			$cb->($result);
		}
	);
}

sub getLyrics {
	my ( $class, $cb, $args ) = @_;

	my @queryParams;
	push @queryParams, 'duration=' . $args->{duration} if $args->{duration} && $args->{duration} =~ /^\d+\.?\d*$/;
	push @queryParams, 'album=' . uri_escape_utf8($args->{album}) if $args->{album};

	my $query = @queryParams ? '?' . join('&', @queryParams) : '';

	my $url = sprintf(LYRICS_URL, uri_escape_utf8($args->{title}), uri_escape_utf8($args->{artist})) . $query;

	_call(
		$url,
		sub {
			my ($result) = @_;
			main::INFOLOG && $log->is_info && $log->info("found lyrics: " . Data::Dump::dump($result));

			if ($result && $result->{instrumental}) {
				$result->{lyrics} = Slim::Utils::Strings::string('PLUGIN_MUSICARTISTINFO_INSTRUMENTAL');
			}

			$cb->($result);
		},{
			radioUrl => $args->{radioUrl},
		}
	)
}

sub getLyricsProviders {
	my ( $class, $cb ) = @_;

	_call(
		LYRICS_PROVIDERS_URL,
		sub {
			my ($result) = @_;

			main::INFOLOG && $log->is_info && $log->info("found lyrics providers: " . Data::Dump::dump($result));

			$cb->($result);
		},
		{
			cache => 0
		}
	);
}

sub getKillwords {
	my ( $class, $cb ) = @_;

	_call(
		KILLWORDS_URL,
		sub {
			$cb->(shift);
		},
		{
			cache => 1,
		}
	)
}

sub hasHitRateLimit {
	return $hitRateLimit ? 1 : 0;
}

sub _call {
	my ($url, $cb, $args) = @_;

	$args ||= {};
	$args->{cache} //= 1;
	$args->{expires} //= '30d';
	$args->{headers} ||= {};
	$args->{headers}->{'x-mai-cfg'} ||= _initXMAICfgString();

	if (Slim::Utils::Misc->can('apiHeaders')) {
		$args->{headers} = { %{$args->{headers}}, Slim::Utils::Misc::apiHeaders(PLUGIN_PACKAGE) };
	}
	else {
		$args->{headers}->{'X-LMS-Plugin-ID'} ||= PLUGIN_PACKAGE;
	}

	# provide radio station URL to help avoiding unnecessary lookups if a station is known to provide no or invalid metadata
	if ($args->{radioUrl} && $args->{radioUrl} =~ m{^https?://} && (my $parsed = URI->new(delete $args->{radioUrl}))) {
		# only submit host name / path to avoid posting potentially sensitive info like stream keys etc.
		$args->{headers}->{'X-LMS-Radio-URL'} = sprintf('%s://%s:%s%s', $parsed->scheme, $parsed->host, $parsed->port, $parsed->path);

		if ($parsed->host =~ /\b(?:tunein|radiotime)\.com$/i) {
			my $queryParams = $parsed->query_form_hash;
			$args->{headers}->{'X-LMS-Radio-URL'} .= '?sid=' . ($queryParams->{id} || 'unknown');
		}
	}

	$queryQueue{$url} ||= [];
	push @{$queryQueue{$url}}, $cb;

	# no need to do the http request if we're already fetching it
	return if scalar @{ $queryQueue{$url} } > 1;

	Plugins::MusicArtistInfo::Common->call($url, sub {
		my ($result, @moreResults) = @_;

		if ($result && ref $result && ref $result eq 'HASH' && $result->{error}) {
			my $error = delete $result->{error};
			$log->error("API call to $url failed: $error");

			$hitRateLimit = 1 if $error =~ /rate limit|\b429\b/i;
		}

		while ( my $cb = shift @{ $queryQueue{$url} }) {
			$cb->($result, @moreResults);
		}

		delete $queryQueue{$url} if @{$queryQueue{$url}} == 0;
	}, $args);
}

sub _prepareAlbumUrl {
	my ($url, $args) = @_;

	my @queryParams;
	push @queryParams, 'mbid=' . $args->{mbid} if $args->{mbid};
	push @queryParams, 'lang=' . $args->{lang} if $args->{lang};

	my ($service, $extid) = split /:album:/, $args->{extid} || '';
	push @queryParams, $service . '=' . $extid if $service && $extid;

	my $query = @queryParams ? '?' . join('&', @queryParams) : '';

	return sprintf($url, uri_escape_utf8($args->{album}), uri_escape_utf8($args->{artist})) . $query;
}

sub _initXMAICfgString {
	my ($renew) = @_;

	if ($renew) {
		$hitRateLimit = 0;
		$xMAICfgString = undef;
	}

	$version ||= (main::SCANNER && Slim::Utils::PluginManager->dataForPlugin('Plugins::MusicArtistInfo::Importer')->{version})
	          || (!main::SCANNER && $Plugins::MusicArtistInfo::Plugin::VERSION) || 'unk';

	my $serverId;

	if (!$xMAICfgString && Slim::Utils::PluginManager->isConfiguredEnabled('Analytics')) {
		eval {
			require Slim::Plugin::Analytics::Plugin;
			if (Slim::Plugin::Analytics::Plugin->can('getServerId')) {
				$serverId = Slim::Plugin::Analytics::Plugin::getServerId();
			}
		};

		# fallback for older LMS versions where the analytics plugin doesn't have getServerId()
		if (!$serverId) {
			# sync with what the analytics plugin does to hash the server ID
			$serverId = sha1_base64(preferences('server')->get('server_uuid'));
			$serverId =~ s/\//+/g;
		}
	}

	return $xMAICfgString ||= sprintf('v:%s,sc:%s,ba:%s,la:%s,ma:%s,ac:%s,pc:%s,si:%s',
		$version,
		main::SCANNER ? 1 : 0,
		$prefs->get('browseArtistPictures') ? 1 : 0,
		$prefs->get('lookupArtistPictures') ? 1 : 0,
		$prefs->get('lookupAlbumArtistPicturesOnly') ? 1 : 0,
		$prefs->get('artistImageFolder') ? 1 : 0,
		$serverPrefs->get('precacheArtwork') ? 1 : 0,
		$serverId || 'undef',
	);
}

1;