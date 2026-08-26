#!/usr/bin/perl

use strict;
use warnings;
use utf8;
use Fcntl qw(:flock);
use FindBin qw($Bin);
use HTTP::Tiny;
use JSON::PP qw(decode_json encode_json);
use POSIX qw(strftime);
use Time::HiRes qw(time sleep);
use URI::Escape qw(uri_escape_utf8);

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

my $config_path = $ARGV[0] || "$Bin/config.conf";
my $self_test = grep { $_ eq '--self-test' } @ARGV;
my $delay_self_test = grep { $_ eq '--delay-self-test' } @ARGV;
my $test_mode = $self_test || $delay_self_test;
my %cfg = load_config($config_path);

my $interval          = number_cfg('CHECK_INTERVAL', 5, 5, 300);
my $failure_seconds   = number_cfg('FAILURE_SECONDS', 20, 10, 3600);
my $cooldown_seconds  = number_cfg('SWITCH_COOLDOWN', 120, 30, 86400);
my $probe_timeout     = number_cfg('PROBE_TIMEOUT', 6, 2, 30);
my $delay_timeout_ms  = number_cfg('DELAY_TIMEOUT_MS', 2500, 1000, 15000);
my $benchmark_concurrency = number_cfg('MAX_BENCHMARK_CONCURRENCY', 64, 1, 256);
my $max_attempts      = number_cfg('MAX_SWITCH_ATTEMPTS', 3, 1, 10);
my $post_switch_wait  = number_cfg('POST_SWITCH_WAIT', 2, 0, 30);
my $required_success  = number_cfg('REQUIRED_SUCCESSES', 1, 1, 20);
my $failed_retry      = number_cfg('FAILED_RETRY_COOLDOWN', 30, 10, 600);
my $confirmation_delay = number_cfg('CONFIRMATION_DELAY', 3, 0, 15);
my $common_failure_limit = number_cfg('COMMON_FAILURE_LIMIT', 2, 1, 10);

my @target_ssids = split_csv($cfg{TARGET_SSIDS} || 'Dbapp-guest,Dbappsecurity');
my @primary_urls = split_csv($cfg{PRIMARY_URLS} ||
    'https://chatgpt.com/backend-api/codex');
my @secondary_urls = split_csv($cfg{SECONDARY_URLS} ||
    'https://www.gstatic.com/generate_204,https://www.cloudflare.com/cdn-cgi/trace');
die "TARGET_SSIDS cannot be empty\n" unless @target_ssids;
die "PRIMARY_URLS cannot be empty\n" unless @primary_urls;
die "SECONDARY_URLS cannot be empty\n" unless @secondary_urls;
$required_success = scalar(@secondary_urls) if $required_success > @secondary_urls;
my $delay_test_url = $cfg{DELAY_TEST_URL} || 'https://chatgpt.com/';

my $controller = $cfg{CONTROLLER_URL} || 'http://127.0.0.1:9090';
$controller =~ s{/+$}{};
die "CONTROLLER_URL must use loopback HTTP (for example http://127.0.0.1:9090)\n"
    unless $controller =~ m{^http://(?:127\.0\.0\.1|localhost):\d+$}i;

my $proxy_url = $cfg{PROXY_URL} || 'http://127.0.0.1:7890';
die "PROXY_URL must use a loopback HTTP/SOCKS proxy\n"
    unless $proxy_url =~ m{^(?:http|socks5h?)://(?:127\.0\.0\.1|localhost):\d+$}i;

my $group              = $cfg{PROXY_GROUP} || 'Proxy';
my $secret             = $cfg{CONTROLLER_SECRET} // '';
$secret = clashx_saved_secret() if $secret =~ /^(?:auto)?$/i;
my $require_sys_proxy  = bool_cfg('REQUIRE_SYSTEM_PROXY', 1);
my $require_codex      = bool_cfg('REQUIRE_CODEX_RUNNING', 1);
my $exclude_pattern    = $cfg{EXCLUDE_PATTERN} || '^(?:DIRECT|REJECT|PASS)$';
my $exclude_re         = eval { qr/$exclude_pattern/i };
die "Invalid EXCLUDE_PATTERN: $@\n" if $@;

my $log_file = expand_path($cfg{LOG_FILE} || '~/Library/Logs/ClashXGuardian.log');
my $lock_file = expand_path($cfg{LOCK_FILE} || '~/Library/Caches/ClashXGuardian.lock');
my $status_file = expand_path($cfg{STATUS_FILE} || '~/Library/Application Support/ClashXGuardian/status.json');
my $trigger_file = expand_path($cfg{TRIGGER_FILE} || '~/Library/Application Support/ClashXGuardian/check-now');
my $runtime_file = expand_path($cfg{RUNTIME_STATE_FILE} || '~/Library/Application Support/ClashXGuardian/runtime-state.json');
ensure_parent($log_file);
ensure_parent($lock_file);
ensure_parent($status_file);
ensure_parent($trigger_file);
ensure_parent($runtime_file);
my $lock_fh;
unless ($test_mode) {
    open $lock_fh, '>>', $lock_file or die "Cannot open lock file $lock_file: $!\n";
    flock($lock_fh, LOCK_EX | LOCK_NB) or die "ClashX Guardian is already running\n";
}

$ENV{no_proxy} = '127.0.0.1,localhost';
$ENV{NO_PROXY} = '127.0.0.1,localhost';
my $http = HTTP::Tiny->new(timeout => 5, keep_alive => 0, verify_SSL => 1);
my $running = 1;
$SIG{TERM} = $SIG{INT} = sub { $running = 0 };

my $wifi_device = find_wifi_device();
my $fail_since;
my $runtime = load_runtime_state();
my $last_switch = 0 + ($runtime->{lastSwitchAt} || 0);
my $last_attempt = 0 + ($runtime->{lastAttemptAt} || 0);
my $candidate_cursor = 0 + ($runtime->{candidateCursor} || 0);
my $node_stats = ref($runtime->{nodeStats}) eq 'HASH' ? $runtime->{nodeStats} : {};
my $recent_events = ref($runtime->{recentEvents}) eq 'ARRAY' ? $runtime->{recentEvents} : [];
@$recent_events = grep {
    ref($_) eq 'HASH' && ($_->{message} // '') !~ /[\x{0080}-\x{009f}]/
} @$recent_events;
run_internal_self_test() if $self_test;
run_delay_self_test() if $delay_self_test;
my $last_healthy = 0;
my $last_state = '';
my $active_ssid = '';
my $current_node = '';
my $last_diagnosis = {
    classification => 'starting', primaryOk => 0,
    secondarySuccesses => 0, secondaryTotal => scalar(@secondary_urls),
};
my ($testing_index, $testing_total, $candidate_node) = (0, 0, '');
log_msg('INFO', "started; Wi-Fi device=" . ($wifi_device || 'not found'));
state_log('starting', 'INFO', 'ClashX Guardian is starting');

while ($running) {
    if (!$wifi_device) {
        state_log('no_wifi_device', 'WARN', 'Wi-Fi hardware port not found; will retry');
        interruptible_sleep($interval);
        $wifi_device = find_wifi_device();
        next;
    }

    my $ssid = current_ssid($wifi_device);
    if (!defined $ssid) {
        state_log('ssid_unavailable', 'WARN',
            'cannot read current SSID; grant Location Services access to the launching app if macOS blocks it');
        $fail_since = undef;
        interruptible_sleep($interval);
        next;
    }
    $active_ssid = $ssid;

    if (!grep { lc($_) eq lc($ssid) } @target_ssids) {
        state_log('inactive_ssid', 'INFO', "inactive on Wi-Fi '$ssid'");
        $fail_since = undef;
        interruptible_sleep($interval);
        next;
    }

    if ($require_codex && !codex_running()) {
        state_log('codex_off', 'INFO', "on '$ssid', but Codex is not running; probes are paused");
        $fail_since = undef;
        interruptible_sleep($interval);
        next;
    }

    if ($require_sys_proxy && !system_proxy_matches()) {
        state_log('system_proxy_off', 'INFO',
            "on '$ssid', but the macOS system proxy is not enabled at the configured local port");
        $fail_since = undef;
        interruptible_sleep($interval);
        next;
    }

    unless (controller_ok()) {
        state_log('controller_off', 'WARN',
            "on '$ssid', but Clash controller is unavailable; automatic switching is impossible");
        $fail_since = undef;
        interruptible_sleep($interval);
        next;
    }
    $current_node = current_selected_node() // $current_node;

    my $diagnosis = diagnose_connectivity();
    $last_diagnosis = $diagnosis;
    if ($diagnosis->{healthy}) {
        $last_healthy = time;
        state_log('healthy', 'INFO', diagnosis_message($diagnosis));
        $fail_since = undef;
        interruptible_sleep($interval);
        next;
    }

    $fail_since //= time;
    my $failed_for = time - $fail_since;
    state_log('unhealthy', 'WARN', sprintf('%s; timer %.0f/%ds', diagnosis_message($diagnosis), $failed_for, $failure_seconds));

    if ($failed_for >= $failure_seconds) {
        my $successful_wait = $last_switch ? $cooldown_seconds - (time - $last_switch) : 0;
        my $failed_wait = ($last_attempt > $last_switch) ? $failed_retry - (time - $last_attempt) : 0;
        my $retry_wait = $successful_wait > $failed_wait ? $successful_wait : $failed_wait;
        if ($retry_wait > 0) {
            state_log('cooldown', 'WARN', sprintf('failure threshold reached; retry available in %.0fs', $retry_wait));
        } else {
            state_log('confirming', 'WARN', 'failure threshold reached; confirming before switching');
            interruptible_sleep($confirmation_delay);
            my $confirmed = diagnose_connectivity();
            $last_diagnosis = $confirmed;
            if ($confirmed->{healthy}) {
                $last_healthy = time;
                state_log('healthy', 'INFO', 'connectivity recovered during switch confirmation');
                $fail_since = undef;
            } else {
                $last_attempt = time;
                save_runtime_state();
                state_log('switching', 'WARN', 'failure confirmed; testing candidate nodes');
                my $switched = switch_to_working_node();
                if ($switched) {
                    $fail_since = undef;
                    $last_state = '';
                } else {
                    state_log('switch_failed', 'ERROR', 'no tested candidate restored connectivity');
                }
            }
        }
    }
    interruptible_sleep($interval);
}

state_log('stopped', 'WARN', 'ClashX Guardian stopped');
log_msg('INFO', 'stopped');
exit 0;

sub load_config {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "Cannot read config $path: $!\n";
    my %out;
    while (my $line = <$fh>) {
        chomp $line;
        $line =~ s/^\s+|\s+$//g;
        next if $line eq '' || $line =~ /^#/;
        die "Invalid config line: $line\n" unless $line =~ /^([A-Z][A-Z0-9_]*)\s*=\s*(.*)$/;
        my ($key, $value) = ($1, $2);
        $value =~ s/^(['"])(.*)\1$/$2/;
        $out{$key} = $value;
    }
    close $fh;
    return %out;
}

sub number_cfg {
    my ($name, $default, $min, $max) = @_;
    my $value = exists $cfg{$name} ? $cfg{$name} : $default;
    die "$name must be a number from $min to $max\n"
        unless $value =~ /^\d+(?:\.\d+)?$/ && $value >= $min && $value <= $max;
    return 0 + $value;
}

sub bool_cfg {
    my ($name, $default) = @_;
    return $default unless exists $cfg{$name};
    return 1 if $cfg{$name} =~ /^(?:1|true|yes|on)$/i;
    return 0 if $cfg{$name} =~ /^(?:0|false|no|off)$/i;
    die "$name must be true or false\n";
}

sub split_csv {
    my ($value) = @_;
    return grep { length } map { s/^\s+|\s+$//gr } split /,/, $value;
}

sub expand_path {
    my ($path) = @_;
    $path =~ s{^~(?=/|$)}{$ENV{HOME}};
    return $path;
}

sub ensure_parent {
    my ($path) = @_;
    my ($parent) = $path =~ m{^(.*)/[^/]+$};
    return unless $parent && !-d $parent;
    require File::Path;
    File::Path::make_path($parent, { mode => 0700 });
}

sub run_capture {
    my (@cmd) = @_;
    open my $fh, '-|', @cmd or return (undef, 127);
    local $/;
    my $output = <$fh> // '';
    close $fh;
    return ($output, $? >> 8);
}

sub clashx_saved_secret {
    my ($output, $status) = run_capture('/usr/bin/defaults', 'read',
        'com.west2online.ClashXPro', 'api-secret');
    return '' if $status || !defined $output;
    $output =~ s/^\s+|\s+$//g;
    return $output;
}

sub find_wifi_device {
    my ($output, $status) = run_capture('/usr/sbin/networksetup', '-listallhardwareports');
    return undef if $status || !defined $output;
    my @lines = split /\n/, $output;
    for (my $i = 0; $i < @lines; $i++) {
        if ($lines[$i] =~ /^Hardware Port:\s*(?:Wi-Fi|AirPort)\s*$/i) {
            return $1 if defined $lines[$i + 1] && $lines[$i + 1] =~ /^Device:\s*(\S+)/;
        }
    }
    return undef;
}

sub current_ssid {
    my ($device) = @_;
    my ($output, $status) = run_capture('/usr/sbin/networksetup', '-getairportnetwork', $device);
    return undef if $status || !defined $output;
    return $1 if $output =~ /Current Wi-Fi Network:\s*(.+?)\s*$/;
    return '' if $output =~ /not associated/i;
    return undef;
}

sub system_proxy_matches {
    my ($output, $status) = run_capture('/usr/sbin/scutil', '--proxy');
    return 0 if $status || !defined $output;
    my ($wanted_host, $wanted_port) = $proxy_url =~ m{://([^:]+):(\d+)$};
    my $http_on  = $output =~ /^\s*HTTPEnable\s*:\s*1\s*$/m;
    my $https_on = $output =~ /^\s*HTTPSEnable\s*:\s*1\s*$/m;
    my $host_ok  = $output =~ /^\s*(?:HTTP|HTTPS)Proxy\s*:\s*\Q$wanted_host\E\s*$/mi;
    my $port_ok  = $output =~ /^\s*(?:HTTP|HTTPS)Port\s*:\s*\Q$wanted_port\E\s*$/m;
    return ($http_on || $https_on) && $host_ok && $port_ok;
}

sub codex_running {
    my (undef, $status) = run_capture('/usr/bin/pgrep', '-if',
        '(/Codex[.]app/|(^|[ /])codex( |$).*(app-server|resume|exec))');
    return $status == 0;
}

sub controller_headers {
    my %headers = ('Content-Type' => 'application/json');
    $headers{Authorization} = "Bearer $secret" if length $secret;
    return \%headers;
}

sub controller_request {
    my ($method, $path, $body, $timeout) = @_;
    local $http->{timeout} = $timeout || 5;
    my %options = (headers => controller_headers());
    $options{content} = encode_json($body) if defined $body;
    return $http->request($method, "$controller$path", \%options);
}

sub controller_ok {
    my $response = controller_request('GET', '/version', undef, 3);
    return $response->{success};
}

sub current_selected_node {
    my $path = '/proxies/' . uri_escape_utf8($group);
    my $response = controller_request('GET', $path, undef, 3);
    return undef unless $response->{success};
    my $data = eval { decode_json($response->{content}) };
    return undef if $@ || ref($data) ne 'HASH';
    return $data->{now};
}

sub confirmed_selected_node {
    my ($target, $reader) = @_;
    $reader ||= \&current_selected_node;
    my $observed = $reader->();
    return $target if defined($observed) && $observed eq $target;
    return undef;
}

sub probe_url {
    my ($url) = @_;
    my @cmd = ('/usr/bin/curl', '--silent', '--show-error', '--output', '/dev/null',
        '--write-out', '%{http_code}', '--connect-timeout', '3', '--max-time', "$probe_timeout",
        '--proxy', $proxy_url, '--url', $url);
    my ($output, $status) = run_capture(@cmd);
    return 0 if $status || !defined $output;
    # 2xx-4xx proves the target endpoint answered. A 5xx may be generated by
    # the local proxy when its upstream node is dead, so it is not healthy.
    return $output =~ /\b[234]\d\d\b/ ? 1 : 0;
}

sub diagnose_connectivity {
    my $primary_ok = 0;
    for my $url (@primary_urls) {
        if (probe_url($url)) {
            $primary_ok = 1;
            last;
        }
    }
    my $ok = 0;
    for my $url (@secondary_urls) {
        $ok++ if probe_url($url);
        last if $ok >= $required_success;
    }
    my $secondary_ok = $ok >= $required_success ? 1 : 0;
    my $classification = $primary_ok && $secondary_ok ? 'healthy'
        : !$primary_ok && $secondary_ok ? 'openai_unreachable'
        : $primary_ok ? 'secondary_degraded'
        : 'route_unreachable';
    return {
        healthy => ($primary_ok && $secondary_ok) ? 1 : 0,
        classification => $classification,
        primaryOk => $primary_ok ? 1 : 0,
        secondarySuccesses => $ok,
        secondaryTotal => scalar(@secondary_urls),
    };
}

sub diagnosis_message {
    my ($diagnosis) = @_;
    my $ok = $diagnosis->{secondarySuccesses} || 0;
    my $total = $diagnosis->{secondaryTotal} || scalar(@secondary_urls);
    return "Codex connectivity healthy (primary reachable, $ok/$total secondary probes)"
        if $diagnosis->{classification} eq 'healthy';
    return "Codex endpoint unreachable while public internet is reachable"
        if $diagnosis->{classification} eq 'openai_unreachable';
    return "Codex endpoint reachable but independent internet probes failed"
        if $diagnosis->{classification} eq 'secondary_degraded';
    return 'multiple reachable nodes failed; shared network or target outage is suspected'
        if $diagnosis->{classification} eq 'shared_outage_suspected';
    return 'Codex and public internet probes are both unreachable through the current node';
}

sub switch_to_working_node {
    my $path = '/proxies/' . uri_escape_utf8($group);
    my $response = controller_request('GET', $path, undef, 5);
    unless ($response->{success}) {
        log_msg('ERROR', "cannot read proxy group '$group': HTTP $response->{status}");
        return 0;
    }

    my $data = eval { decode_json($response->{content}) };
    if ($@ || ref($data) ne 'HASH' || ($data->{type} // '') ne 'Selector' || ref($data->{all}) ne 'ARRAY') {
        log_msg('ERROR', "'$group' is missing or is not a Selector proxy group");
        return 0;
    }

    my $current = $data->{now} // '';
    my @all_candidates = grep { defined && length && $_ ne $current && $_ !~ $exclude_re } @{$data->{all}};
    $testing_total = scalar(@all_candidates);
    $testing_index = 0;
    $candidate_node = "ClashX 延迟测速 · $testing_total 个节点";
    write_status('switching', 'WARN', 'running ClashX full latency benchmark');
    log_msg('INFO', "running ClashX-style full benchmark for " . scalar(@all_candidates)
        . " candidates in '$group' (current='$current')");

    my @working = parallel_delay_tests(benchmark_parallel_limit(scalar(@all_candidates)), @all_candidates);
    return 0 unless $running;
    @working = sort_measured_candidates(@working);
    log_msg('INFO', 'ClashX-style benchmark returned ' . scalar(@working) . ' reachable candidates');
    splice(@working, $max_attempts) if @working > $max_attempts;
    my $common_failures = 0;
    for my $candidate (@working) {
        last unless $running;
        my ($delay, $name) = @$candidate;
        $candidate_node = "$name · ${delay} ms";
        write_status('switching', 'WARN', "verifying lowest-latency candidate '$name' (${delay}ms)");
        my $put = controller_request('PUT', $path, { name => $name }, 5);
        my $selected = confirmed_selected_node($name);
        unless (defined $selected) {
            log_msg('WARN', "selector did not confirm '$name' after PUT: HTTP $put->{status}");
            next;
        }
        log_msg('WARN', "PUT for '$name' returned HTTP $put->{status}, but controller state confirms selection")
            unless $put->{success};
        log_msg('INFO', "selected '$name' (${delay}ms); verifying connectivity");
        interruptible_sleep($post_switch_wait);
        last unless $running;
        my $diagnosis = diagnose_connectivity();
        $last_diagnosis = $diagnosis;
        if ($diagnosis->{healthy}) {
            $current_node = $name;
            $last_healthy = time;
            $last_switch = time;
            record_node_result($name, 1, $delay);
            record_event('switched', "已切换到 $name（${delay} ms），Codex 线路恢复");
            save_runtime_state();
            log_msg('INFO', "node '$name' restored Codex connectivity (primary reachable, "
                . $diagnosis->{secondarySuccesses} . '/' . scalar(@secondary_urls) . ' secondary probes)');
            write_status('healthy', 'INFO', "node '$name' restored Codex connectivity");
            $last_state = 'healthy';
            ($testing_index, $testing_total, $candidate_node) = (0, 0, '');
            return 1;
        }
        record_node_result($name, 0, $delay);
        $common_failures++ if $diagnosis->{classification} eq 'route_unreachable';
        log_msg('WARN', "node '$name' passed delay test but failed full connectivity check ("
            . $diagnosis->{classification} . ')');
        if ($common_failures >= $common_failure_limit) {
            $last_diagnosis = {
                %$diagnosis,
                classification => 'shared_outage_suspected',
            };
            log_msg('WARN', 'multiple reachable candidates failed the same full check; shared outage suspected');
            last;
        }
    }
    my $switch_failed_message = '候选节点均未通过完整连通性检查';
    if (length $current) {
        my $restore = controller_request('PUT', $path, { name => $current }, 5);
        my $observed = current_selected_node();
        if (defined($observed) && $observed eq $current) {
            $current_node = $current;
            log_msg('WARN', "all candidates failed; restored previous node '$current'");
            $switch_failed_message .= '，已恢复原节点';
        } elsif (defined($observed) && length($observed)) {
            $current_node = $observed;
            log_msg('ERROR', "restore PUT returned HTTP $restore->{status}; controller reports '$observed'");
            $switch_failed_message .= "，当前节点为 $observed";
        } else {
            $current_node = '';
            log_msg('ERROR', "restore PUT returned HTTP $restore->{status}; active node could not be confirmed");
            $switch_failed_message .= '，无法确认当前节点';
        }
    }
    record_event('switch_failed', $switch_failed_message);
    save_runtime_state();
    ($testing_index, $testing_total, $candidate_node) = (0, 0, '');
    return 0;
}

sub measure_candidate_delay {
    my ($name) = @_;
    my $candidate_path = '/proxies/' . uri_escape_utf8($name) . '/delay'
        . '?timeout=' . int($delay_timeout_ms)
        . '&url=' . uri_escape_utf8($delay_test_url);
    my $response = controller_request('GET', $candidate_path, undef, ($delay_timeout_ms / 1000) + 2);
    return undef unless $response->{success};
    my $data = eval { decode_json($response->{content}) };
    return undef if $@ || ref($data) ne 'HASH' || ($data->{delay} // '') !~ /^\d+$/
        || $data->{delay} <= 0;
    return 0 + $data->{delay};
}

sub sort_measured_candidates {
    my @valid = grep {
        ref($_) eq 'ARRAY'
            && defined($_->[0]) && $_->[0] =~ /^\d+$/ && $_->[0] > 0
            && defined($_->[1]) && length($_->[1])
    } @_;
    return sort {
        $a->[0] <=> $b->[0]
            || node_score($b->[1]) <=> node_score($a->[1])
            || $a->[1] cmp $b->[1]
    } @valid;
}

sub benchmark_parallel_limit {
    my ($candidate_count) = @_;
    return 1 if !$candidate_count || $candidate_count < 1;
    return $candidate_count < $benchmark_concurrency ? $candidate_count : $benchmark_concurrency;
}

sub parallel_delay_tests {
    my ($parallel_limit, @candidates) = @_;
    $parallel_limit = 1 if $parallel_limit < 1;
    my @working;
    $testing_total = scalar(@candidates);
    $testing_index = 0;
    while (@candidates && $running) {
        my @batch = splice(@candidates, 0, $parallel_limit);
        my $first = $testing_index + 1;
        my $last = $testing_index + scalar(@batch);
        $candidate_node = "ClashX 延迟测速 · $first-$last/$testing_total";
        write_status('switching', 'WARN', "testing candidates $first-$last/$testing_total") unless $delay_self_test;
        my @children;
        for my $name (@batch) {
            my ($reader, $writer);
            unless (pipe($reader, $writer)) {
                $testing_index++;
                $candidate_node = "$name · 启动失败";
                log_msg('WARN', "cannot create benchmark pipe for '$name': $!");
                write_status('switching', 'WARN', "ClashX latency benchmark $testing_index/$testing_total")
                    unless $delay_self_test;
                next;
            }
            my $pid = fork();
            if (!defined $pid) {
                close $reader; close $writer;
                $testing_index++;
                $candidate_node = "$name · 启动失败";
                log_msg('WARN', "cannot start benchmark worker for '$name': $!");
                write_status('switching', 'WARN', "ClashX latency benchmark $testing_index/$testing_total")
                    unless $delay_self_test;
                next;
            }
            if ($pid == 0) {
                close $reader;
                my $delay = measure_candidate_delay($name);
                print {$writer} defined($delay) ? "$delay\n" : "\n";
                close $writer;
                POSIX::_exit(0);
            }
            close $writer;
            push @children, [$pid, $reader, $name];
        }
        for my $child (@children) {
            my ($pid, $reader, $name) = @$child;
            waitpid($pid, 0);
            my $value = <$reader>;
            close $reader;
            chomp $value if defined $value;
            push @working, [0 + $value, $name]
                if defined($value) && $value =~ /^\d+$/ && $value > 0;
            $testing_index++;
            $candidate_node = defined($value) && $value =~ /^\d+$/
                ? "$name · ${value} ms"
                : "$name · 失败";
            write_status('switching', 'WARN', "ClashX latency benchmark $testing_index/$testing_total")
                unless $delay_self_test;
        }
    }
    return @working;
}

sub node_score {
    my ($name) = @_;
    my $stats = ref($node_stats->{$name}) eq 'HASH' ? $node_stats->{$name} : {};
    my $score = 0;
    $score += 120 * ($stats->{successes} || 0);
    $score -= 35 * ($stats->{failures} || 0);
    $score -= 160 * ($stats->{consecutiveFailures} || 0);
    $score += 250 if ($stats->{lastSuccessAt} || 0) > time - 86400;
    $score -= 400 if ($stats->{lastFailureAt} || 0) > time - 300;
    $score -= int(($stats->{averageDelay} || 0) / 20);
    return $score;
}

sub ranked_candidates {
    my (@names) = @_;
    return () unless @names;
    my $offset = $candidate_cursor % scalar(@names);
    my @rotated = @names[$offset .. $#names];
    push @rotated, @names[0 .. $offset - 1] if $offset > 0;
    my %position;
    @position{@rotated} = (0 .. $#rotated);
    return sort { node_score($b) <=> node_score($a) || $position{$a} <=> $position{$b} } @rotated;
}

sub record_node_result {
    my ($name, $success, $delay) = @_;
    my $stats = $node_stats->{$name} ||= {};
    if ($success) {
        $stats->{successes} = 1 + ($stats->{successes} || 0);
        $stats->{consecutiveFailures} = 0;
        $stats->{lastSuccessAt} = int(time);
    } else {
        $stats->{failures} = 1 + ($stats->{failures} || 0);
        $stats->{consecutiveFailures} = 1 + ($stats->{consecutiveFailures} || 0);
        $stats->{lastFailureAt} = int(time);
    }
    if (defined $delay) {
        my $samples = 1 + ($stats->{delaySamples} || 0);
        my $previous = $stats->{averageDelay} || $delay;
        $stats->{averageDelay} = int((($previous * ($samples - 1)) + $delay) / $samples);
        $stats->{delaySamples} = $samples;
    }
}

sub run_internal_self_test {
    $candidate_cursor = 0;
    $node_stats = {
        stable => { successes => 3, failures => 0, lastSuccessAt => int(time), averageDelay => 450 },
        recent_failed => { successes => 4, failures => 1, consecutiveFailures => 1,
            lastFailureAt => int(time), averageDelay => 100 },
    };
    my @ranked = ranked_candidates(qw(untested_a stable recent_failed untested_b));
    die "self-test failed: stable node was not preferred\n" unless $ranked[0] eq 'stable';
    die "self-test failed: recently failed node was not penalized\n" unless $ranked[-1] eq 'recent_failed';
    my %seen = map { $_ => 1 } @ranked;
    die "self-test failed: candidate rotation lost entries\n" unless @ranked == 4 && keys(%seen) == 4;
    my $message = diagnosis_message({ classification => 'openai_unreachable', secondarySuccesses => 1, secondaryTotal => 2 });
    die "self-test failed: diagnosis text\n" unless $message =~ /OpenAI|Codex/i;
    my @measured = sort_measured_candidates([420, 'slow'], [78, 'fast'], [0, 'timeout']);
    die "self-test failed: ClashX benchmark did not prefer the lowest live latency\n"
        unless @measured == 2
            && $measured[0]->[1] eq 'fast' && $measured[0]->[0] == 78
            && $measured[1]->[1] eq 'slow' && $measured[1]->[0] == 420;
    my @tied = sort_measured_candidates([120, 'aaa_new'], [120, 'stable']);
    die "self-test failed: equal latency did not use reliability as a tie-breaker\n"
        unless @tied == 2 && $tied[0]->[1] eq 'stable';
    die "self-test failed: benchmark concurrency limit\n"
        unless benchmark_parallel_limit(44) == 44
            && benchmark_parallel_limit(120) == 64;
    my $selected_after_timeout = confirmed_selected_node(
        'fast', sub { return 'fast'; }
    );
    die "self-test failed: ambiguous PUT was not resolved from controller state\n"
        unless defined($selected_after_timeout) && $selected_after_timeout eq 'fast';
    my $wrong_selection = confirmed_selected_node(
        'fast', sub { return 'slow'; }
    );
    die "self-test failed: mismatched selector state was accepted\n"
        if defined $wrong_selection;
    print "guardian_self_test_ok=1 ranked=" . join(',', @ranked) . "\n";
    exit 0;
}

sub run_delay_self_test {
    my $path = '/proxies/' . uri_escape_utf8($group);
    my $response = controller_request('GET', $path, undef, 5);
    die "delay self-test failed: controller or proxy group unavailable\n" unless $response->{success};
    my $data = eval { decode_json($response->{content}) };
    die "delay self-test failed: invalid selector response\n"
        if $@ || ref($data) ne 'HASH' || ref($data->{all}) ne 'ARRAY';
    my $current = $data->{now} // '';
    my @candidates = grep { defined && length && $_ ne $current && $_ !~ $exclude_re } @{$data->{all}};
    my $started = time;
    my $parallel_limit = benchmark_parallel_limit(scalar(@candidates));
    my @working = parallel_delay_tests($parallel_limit, @candidates);
    @working = sort_measured_candidates(@working);
    my $elapsed = time - $started;
    die "delay self-test failed: no candidate answered\n" unless @working;
    print sprintf("delay_self_test_ok=1 source=clashx-ui tested=%d reachable=%d best=%s best_delay=%dms elapsed=%.2fs parallel=%d\n",
        scalar(@candidates), scalar(@working), $working[0]->[1], $working[0]->[0],
        $elapsed, $parallel_limit);
    exit 0;
}

sub interruptible_sleep {
    my ($seconds) = @_;
    my $until = time + $seconds;
    while ($running && time < $until) {
        if (-e $trigger_file) {
            unlink $trigger_file;
            log_msg('INFO', 'immediate check requested from menu bar');
            last;
        }
        sleep((($until - time) > 1) ? 1 : ($until - time));
    }
}

sub state_log {
    my ($state, $level, $message) = @_;
    my $previous = $last_state;
    my $changed = $state ne $previous;
    if ($changed) {
        if ($state eq 'unhealthy') {
            record_event('unhealthy', '检测到线路异常，正在等待确认');
        } elsif ($state eq 'healthy' && $previous =~ /^(?:unhealthy|cooldown|switch_failed)$/) {
            my $elapsed = defined($fail_since) ? int(time - $fail_since) : 0;
            record_event('recovered', "线路自行恢复，用时 ${elapsed} 秒");
        } elsif ($state eq 'controller_off') {
            record_event('controller_off', 'ClashX Pro 控制接口不可用');
        } elsif ($state eq 'switching') {
            record_event('switching', '开始测试候选节点');
        } elsif ($state eq 'stopped') {
            record_event('stopped', '自动保护已停止');
        }
    }
    write_status($state, $level, $message);
    return unless $changed;
    $last_state = $state;
    log_msg($level, $message);
}

sub load_runtime_state {
    return {} unless -f $runtime_file;
    open my $fh, '<:raw', $runtime_file or return {};
    local $/;
    my $content = <$fh> // '';
    close $fh;
    my $decoded = eval { decode_json($content) };
    return {} if $@ || ref($decoded) ne 'HASH';
    return $decoded;
}

sub save_runtime_state {
    my $payload = {
        schemaVersion => 1,
        lastAttemptAt => $last_attempt ? int($last_attempt) : undef,
        lastSwitchAt => $last_switch ? int($last_switch) : undef,
        candidateCursor => $candidate_cursor,
        nodeStats => $node_stats,
        recentEvents => $recent_events,
    };
    my $temporary = "$runtime_file.tmp.$$";
    if (open my $fh, '>:raw', $temporary) {
        print {$fh} encode_json($payload);
        close $fh;
        chmod 0600, $temporary;
        rename $temporary, $runtime_file or unlink $temporary;
    }
}

sub record_event {
    my ($type, $message) = @_;
    my $last = @$recent_events ? $recent_events->[-1] : undef;
    return if $last && ($last->{type} // '') eq $type && ($last->{message} // '') eq $message;
    push @$recent_events, { timestamp => int(time), type => $type, message => $message };
    shift @$recent_events while @$recent_events > 8;
    save_runtime_state();
}

sub write_status {
    my ($state, $level, $message) = @_;
    my $now = time;
    my $payload = {
        schemaVersion  => 1,
        state          => $state,
        level          => lc($level),
        message        => $message,
        timestamp      => int($now),
        checkedAt      => strftime('%Y-%m-%dT%H:%M:%S%z', localtime($now)),
        ssid           => $active_ssid,
        wifiDevice     => $wifi_device // '',
        currentNode    => $current_node,
        proxyGroup     => $group,
        failureSince   => defined($fail_since) ? int($fail_since) : undef,
        failureElapsed => defined($fail_since) ? int($now - $fail_since) : 0,
        failureSeconds => int($failure_seconds),
        lastHealthyAt  => $last_healthy ? int($last_healthy) : undef,
        lastAttemptAt  => $last_attempt ? int($last_attempt) : undef,
        lastSwitchAt   => $last_switch ? int($last_switch) : undef,
        diagnosis      => $last_diagnosis->{classification} || 'unknown',
        primaryOk      => $last_diagnosis->{primaryOk} ? 1 : 0,
        secondarySuccesses => 0 + ($last_diagnosis->{secondarySuccesses} || 0),
        secondaryTotal => 0 + ($last_diagnosis->{secondaryTotal} || scalar(@secondary_urls)),
        testingIndex   => $testing_index,
        testingTotal   => $testing_total,
        candidateNode  => $candidate_node,
        recentEvents   => $recent_events,
        pid            => $$,
    };
    my $temporary = "$status_file.tmp.$$";
    if (open my $fh, '>:raw', $temporary) {
        print {$fh} encode_json($payload);
        close $fh;
        chmod 0600, $temporary;
        rename $temporary, $status_file or unlink $temporary;
    }
}

sub log_msg {
    my ($level, $message) = @_;
    if (-f $log_file && -s $log_file > 512 * 1024) {
        unlink "$log_file.1";
        rename $log_file, "$log_file.1";
    }
    open my $fh, '>>:encoding(UTF-8)', $log_file or return;
    chmod 0600, $log_file;
    print {$fh} strftime('%Y-%m-%d %H:%M:%S', localtime) . " [$level] $message\n";
    close $fh;
}
