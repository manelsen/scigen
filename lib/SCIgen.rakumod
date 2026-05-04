unit module SCIgen;

constant DEFAULT-PORT is export = 4724;
constant DEFAULT-OPENAI-COMPAT-BASE-URL is export = 'https://api.openai.com/v1';

class DeterministicRandom is export {
    has Int $.state is rw;

    method new(Int :$seed = 1) {
        my $state = $seed % 2_147_483_647;
        $state += 2_147_483_646 if $state <= 0;
        self.bless(:$state);
    }

    method next-num(--> Num) {
        $!state = ($!state * 48_271) % 2_147_483_647;
        ($!state / 2_147_483_647).Num;
    }

    method pick-index(Int:D $count --> Int) {
        die "Cannot pick from an empty rule set" if $count <= 0;
        (self.next-num * $count).floor.Int;
    }
}

class RuleBook is export {
    has %.rules;
    has %.unique-history;
    has %.include-seen;
    has %.counters;
    has Int $.max-expansions is rw = 12_000;
    has Int $.expansions is rw = 0;
    has @!token-cache;
    has Bool $!token-cache-dirty = True;

    method add-rule(Str:D $name, Str:D $body, Int:D $weight = 1) {
        my $rules = %!rules{$name} //= [];
        for ^$weight {
            $rules.push($body);
        }
        $!token-cache-dirty = True;
    }

    method set-rule(Str:D $name, Str:D $body) {
        %!rules{$name} = [$body];
        $!token-cache-dirty = True;
    }

    method replace-rules(Str:D $name, @bodies) {
        %!rules{$name} = @bodies;
        $!token-cache-dirty = True;
    }

    method mark-unique(Str:D $name) {
        %!unique-history{$name} //= [];
    }

    method is-unique(Str:D $name --> Bool) {
        %!unique-history{$name}:exists;
    }

    method has-generated(Str:D $name, Str:D $value --> Bool) {
        return False unless self.is-unique($name);
        %!unique-history{$name}.grep(* eq $value).Bool;
    }

    method remember-generated(Str:D $name, Str:D $value) {
        return unless self.is-unique($name);
        %!unique-history{$name}.push($value);
    }

    method mark-include(IO::Path:D $path) {
        %!include-seen{$path.absolute.Str} = True;
    }

    method saw-include(IO::Path:D $path --> Bool) {
        %!include-seen{$path.absolute.Str}:exists;
    }

    method alternatives(Str:D $name) {
        %!rules{$name} // [];
    }

    method next-counter(Str:D $name --> Int) {
        my $current = %!counters{$name} // 0;
        %!counters{$name} = $current + 1;
        $current;
    }

    method any-counter(Str:D $name, DeterministicRandom:D $rng --> Int) {
        my $max = %!counters{$name} // 0;
        return 0 if $max <= 0;
        $rng.pick-index($max);
    }

    method match-tokens(--> List) {
        if $!token-cache-dirty {
            @!token-cache = %!rules.keys
            .map({ token-from-rule-name($_) })
            .grep(*.chars > 0)
            .unique
            .sort({ $^b.chars <=> $^a.chars })
            .List;
            $!token-cache-dirty = False;
        }
        @!token-cache.List;
    }
}

class TokenMatch is export {
    has Str $.before;
    has Str $.token;
    has Str $.after;
}

class LLMConfig is export {
    has Str $.base-url = DEFAULT-OPENAI-COMPAT-BASE-URL;
    has Str $.api-key = '';
    has Str $.model = '';

    method enabled(--> Bool) {
        $!api-key.chars > 0 && $!model.chars > 0;
    }

    method chat-url(--> Str) {
        $!base-url.subst(/'/'*$/, '') ~ '/chat/completions';
    }
}

sub openai-compatible-config(
    Str :$base-url = %*ENV<SCIGEN_LLM_BASE_URL> // DEFAULT-OPENAI-COMPAT-BASE-URL,
    Str :$api-key = %*ENV<SCIGEN_LLM_API_KEY> // %*ENV<OPENAI_API_KEY> // '',
    Str :$model = %*ENV<SCIGEN_LLM_MODEL> // '',
    --> LLMConfig
) is export {
    LLMConfig.new(:$base-url, :$api-key, :$model);
}

sub read-dotenv(Str:D $path = '.env' --> Hash) is export {
    my %values;
    my $file = $path.IO;
    return %values unless $file.e;

    for $file.lines -> $line is copy {
        $line .= trim;
        next unless $line.chars;
        next if $line.starts-with('#');
        $line ~~ s/^ 'export' \s+ //;
        my ($key, $value) = $line.split('=', 2);
        next unless $key.defined && $value.defined;
        $key = $key.trim;
        next unless $key ~~ /^ <[A..Z a..z _]> <[A..Z a..z 0..9 _]>* $/;
        %values{$key} = unquote-dotenv-value($value.trim);
    }

    %values;
}

sub unquote-dotenv-value(Str:D $value --> Str) {
    if $value.chars >= 2 {
        my $first = $value.substr(0, 1);
        my $last = $value.substr($value.chars - 1, 1);
        if ($first eq '"' && $last eq '"') || ($first eq "'" && $last eq "'") {
            return $value.substr(1, $value.chars - 2);
        }
    }
    $value;
}

sub getenv-with-dotenv(Str:D $key, %dotenv, Str $default = '' --> Str) is export {
    (%*ENV{$key} // %dotenv{$key} // $default).Str;
}

sub require-llm-config(LLMConfig:D $config) is export {
    die "LLM analysis requires SCIGEN_LLM_API_KEY or OPENAI_API_KEY" unless $config.api-key.chars;
    die "LLM analysis requires --llm-model or SCIGEN_LLM_MODEL" unless $config.model.chars;
}

sub llm-analysis-request(Str:D $text, LLMConfig:D $config, Str :$system = default-analysis-system-prompt() --> Hash) is export {
    require-llm-config($config);
    {
        model => $config.model,
        messages => [
            { role => 'system', content => $system },
            { role => 'user', content => $text },
        ],
        temperature => 0.2,
    }
}

sub default-analysis-system-prompt(--> Str) is export {
    'Analyze academic metadata or abstracts. Extract cautious themes, relevant concepts, and citation-safe notes. Do not invent citations or claims.'
}

sub analyze-with-openai-compatible(Str:D $text, LLMConfig:D $config --> Str) is export {
    call-llm-chat($config, default-analysis-system-prompt(), $text, temperature => 0.2e0);
}

sub json-escape-str(Str:D $s --> Str) is export {
    $s.subst('\\', '\\\\', :g)
      .subst('"', '\\"', :g)
      .subst("\n", '\\n', :g)
      .subst("\t", '\\t', :g)
      .subst("\r", '\\r', :g);
}

sub build-chat-payload(Str:D $model, Str:D $system, Str:D $user, Num:D $temp --> Str) is export {
    '{' ~ "\n"
    ~ '  "model": "' ~ json-escape-str($model) ~ '",' ~ "\n"
    ~ '  "messages": [' ~ "\n"
    ~ '    {"role": "system", "content": "' ~ json-escape-str($system) ~ '"},' ~ "\n"
    ~ '    {"role": "user", "content": "' ~ json-escape-str($user) ~ '"}' ~ "\n"
    ~ '  ],' ~ "\n"
    ~ '  "temperature": ' ~ $temp ~ "\n"
    ~ '}';
}

sub call-llm-chat(
    LLMConfig:D $config,
    Str:D $system-prompt,
    Str:D $user-prompt,
    Num :$temperature = 0.7e0
    --> Str
) is export {
    require-llm-config($config);
    require-tools('LLM chat', <curl jq>);

    my $payload = build-chat-payload($config.model, $system-prompt, $user-prompt, $temperature);
    my $tmp = $*TMPDIR.add("scigen-llm-$*PID-{(^100000).pick}.json");
    $tmp.spurt($payload);
    LEAVE $tmp.unlink if $tmp.defined && $tmp.e;

    my $curl-proc = run 'curl', '-s', '-X', 'POST',
        '-H', 'Content-Type: application/json',
        '-H', "Authorization: Bearer {$config.api-key}",
        '--data-binary', '@' ~ $tmp.Str,
        $config.chat-url,
        :out, :err;

    my $response = $curl-proc.out.slurp;
    $curl-proc.out.close;

    if $curl-proc.exitcode != 0 {
        my $err = $curl-proc.err.defined ?? $curl-proc.err.slurp !! '';
        die "LLM request failed (curl exit {$curl-proc.exitcode}): $err";
    }

    my $jq-proc = run 'jq', '-r', '.choices[0].message.content', :in, :out;
    $jq-proc.in.spurt($response);
    $jq-proc.in.close;
    my $content = $jq-proc.out.slurp;
    $jq-proc.out.close;

    die "LLM response extraction failed (jq exit {$jq-proc.exitcode})" if $jq-proc.exitcode != 0;
    $content.trim;
}

sub domain-ai-prompt(Str:D $domain --> Str) is export {
    qq:to/PROMPT/
    You are a domain terminology generator for SCIgen, an academic paper generator.

    Given a domain name, generate domain-specific entries for the following grammar rules.
    Each entry must be on its own line in the format: RULE_NAME<TAB>value

    Rules to generate for the domain "{$domain}":
    - SCI_FIELD: 16 entries — subfield or specialization names (e.g., "genetics", "molecular biology")
    - SCI_THING_S: 20 entries — singular technical concepts/objects, with "the" where natural (e.g., "the genome", "protein folding")
    - SCI_THING_P: 20 entries — plural technical concepts/objects (e.g., "enzymes", "proteins")
    - SCI_PEOPLE: 17 entries — types of researchers or professionals (e.g., "biologists", "geneticists")
    - SCI_BUZZWORD_NOUN: 20 entries — technical nouns for buzzword phrases (e.g., "sequencing", "expression")

    Requirements:
    - All entries must be realistic and specific to the {$domain} domain
    - Use lowercase unless proper nouns require capitalization
    - No duplicates within a rule
    - Output ONLY tab-separated entries, no markdown, no code blocks, no other text
    PROMPT
}

sub parse-domain-ai-response(Str:D $text --> Hash) is export {
    my %rules;
    for $text.lines -> $line is copy {
        $line .= trim;
        next unless $line.chars;
        next if $line.starts-with('#');
        my ($name, $value) = $line.split(/\t/, 2);
        next unless $name.defined && $value.defined;
        $name .= trim;
        $value .= trim;
        next unless $name.chars && $value.chars;
        %rules{$name}.push($value);
    }
    %rules;
}

sub apply-domain-ai(RuleBook:D $book, Str:D $domain, LLMConfig:D $config --> RuleBook) is export {
    my $system = domain-ai-prompt($domain);
    my $user = "Generate entries for the domain: {$domain}";
    my $response = call-llm-chat($config, $system, $user);
    my %rules = parse-domain-ai-response($response);
    die "LLM generated no valid rules for domain '$domain'" unless %rules;
    for %rules.kv -> $name, @alternatives {
        $book.replace-rules($name, @alternatives.list.map(*.Str));
    }
    $book;
}

sub token-from-rule-name(Str:D $name --> Str) is export {
    $name.subst('\\+', '+', :g).subst('\\#', '#', :g);
}

sub load-rules(Str:D $path, *%bindings, :%overrides --> RuleBook) is export {
    my $book = RuleBook.new;
    parse-rule-file($path.IO, $book);
    for %bindings.kv -> $name, $values {
        my @values = $values ~~ Positional ?? $values.list !! [$values];
        $book.add-rule($name, .Str) for @values;
    }
    for %overrides.kv -> $name, $values {
        my @values = $values ~~ Positional ?? $values.list !! [$values];
        $book.set-rule($name, .Str) for @values;
    }
    $book;
}

sub resolve-domain-path(Str:D $domain --> IO::Path) is export {
    # explicit path: contains / or .in suffix
    return $domain.IO if $domain.contains('/') || $domain.ends-with('.in');
    # shorthand: domains/<name>.in
    my $candidate = "domains/$domain.in".IO;
    return $candidate if $candidate.e;
    # fallback: <name>.in in cwd
    "$domain.in".IO;
}

sub apply-domain(RuleBook:D $book, Str:D $domain --> RuleBook) is export {
    my $path = resolve-domain-path($domain);
    die "Domain profile not found: $domain (tried $path)" unless $path.e;
    my $temp = RuleBook.new;
    parse-rule-file($path, $temp);
    for $temp.rules.kv -> $name, $alternatives {
        $book.replace-rules($name, $alternatives.list.map(*.Str));
    }
    $book;
}

sub parse-rule-file(IO::Path:D $path, RuleBook:D $book) is export {
    my $source = $path.absolute.IO;
    return if $book.saw-include($source);
    $book.mark-include($source);

    my $handle = $source.open(:r);
    LEAVE $handle.close if $handle.defined;

    while defined(my $line = $handle.get) {
        next if $line ~~ /^\s* '#'/;
        next unless $line ~~ /\S/;

        my @words = $line.words;
        my $name = @words.shift;

        if $name.ends-with('.include') {
            my $include = resolve-include($source.parent, @words[0]);
            parse-rule-file($include, $book);
            next;
        }

        if $name.ends-with('!') {
            $book.mark-unique($name.substr(0, $name.chars - 1));
            next;
        }

        my $body = @words.elems == 1 && @words[0] eq '{'
            ?? read-block($handle, $name)
            !! body-after-name($line);

        my $weight = 1;
        if $name ~~ /^(.*?) '+' (\d+) $/ {
            $name = ~$0;
            $weight = +$1;
        }

        $book.add-rule($name, $body, $weight);
    }
}

sub resolve-include(IO::Path:D $base, Str:D $file --> IO::Path) {
    my $candidate = $file.IO;
    return $candidate if $candidate.is-absolute;

    my $relative = $base.add($file);
    return $relative if $relative.e;
    $candidate;
}

sub read-block(IO::Handle:D $handle, Str:D $name --> Str) {
    my @lines;
    while defined(my $line = $handle.get) {
        return @lines.join("\n") ~ "\n" if $line ~~ /^ '}' \s* $/;
        @lines.push($line);
    }
    die "$name: EOF found before close rule";
}

sub body-after-name(Str:D $line --> Str) {
    $line.subst(/^\S+ \s*/, '');
}

sub generate(RuleBook:D $book, Str:D $start = 'START', Int :$seed = 1, Bool :$pretty = True --> Str) is export {
    my $rng = DeterministicRandom.new(seed => $seed);
    my $output = expand($book, $start, $rng);
    $pretty ?? format-output($output) !! $output;
}

sub expand(RuleBook:D $book, Str:D $start, DeterministicRandom:D $rng, Int :$depth = 0 --> Str) is export {
    return '' if $book.expansions++ > $book.max-expansions;
    return '' if $depth > 240;

    if $start.ends-with('+') {
        return $book.next-counter($start.substr(0, $start.chars - 1)).Str;
    }

    if $start.ends-with('#') {
        return $book.any-counter($start.substr(0, $start.chars - 1), $rng).Str;
    }

    my @alternatives = $book.alternatives($start).list;
    die "No rule named '$start'" unless @alternatives;

    my $full-token = '';
    my $repeat = False;
    my $count = 0;

    repeat {
        my $input = $depth > 120
            ?? @alternatives.sort({ $^a.chars <=> $^b.chars })[0]
            !! @alternatives[$rng.pick-index(@alternatives.elems)];
        $count++;
        my @components;

        while my $match = find-next-token($book, $input) {
            @components.push($match.before) if $match.before.chars;
            my $expanded = expand($book, $match.token, $rng, :depth($depth + 1));
            @components.push($expanded) if $expanded.chars;
            $input = $match.after;
        }
        @components.push($input) if $input.chars;
        $full-token = @components.join('');

        $repeat = $book.has-generated($start, $full-token);
        if !$repeat {
            $book.remember-generated($start, $full-token);
        } elsif $count > 50 {
            $repeat = False;
        }
    } while $repeat;

    $full-token;
}

sub find-next-token(RuleBook:D $book, Str:D $input --> TokenMatch) is export {
    my @tokens = $book.match-tokens;
    my $best-pos;
    my $best-token;

    for @tokens -> $token {
        my $pos = $input.index($token);
        next unless $pos.defined;
        if !$best-pos.defined || $pos < $best-pos || ($pos == $best-pos && $token.chars > $best-token.chars) {
            $best-pos = $pos;
            $best-token = $token;
        }
    }

    if $best-pos.defined {
        my $tail = $input.substr($best-pos);
        return TokenMatch.new(
            before => $input.substr(0, $best-pos),
            token => $best-token,
            after => $tail.substr($best-token.chars),
        );
    }
    Nil;
}

sub format-output(Str:D $text --> Str) is export {
    my @lines = $text.lines.map({
        my $line = $_
            .subst(/(\s+) (<[.,?;:]>) /, -> $/ { ~$1 }, :g);
        sentence-case($line);
    });
    @lines.join("\n");
}

sub sentence-case(Str:D $line --> Str) {
    return $line if $line ~~ /^\s* '\\'/;
    return $line unless $line ~~ /\S/;
    $line.substr(0, 1).uc ~ $line.substr(1);
}

sub generate-system-name(Int :$seed = 1, Bool :$effects = True --> Str) is export {
    my $book = load-rules('system_names.in');
    my $rng = DeterministicRandom.new(:$seed);
    my $name = expand($book, 'SYSTEM_NAME', $rng).trim;

    if $effects {
        my $roll = $rng.next-num;
        if $roll < 0.1 {
            $name = '{\em ' ~ $name ~ '}';
        } elsif $name.chars <= 6 && $roll < 0.4 {
            $name = $name.uc;
        }
    }

    $name;
}

sub write-paper(*%opts --> IO::Path) is export {
    my Int $seed = (%opts<seed> // 1).Int;
    my Bool $talk = ?(%opts<talk> // False);
    my $title = %opts<title>;
    my $abstract = %opts<abstract>;
    my $start-override = %opts<start>;
    my $sysname = %opts<sysname>;
    my @authors = (%opts<authors> // []).list;
    my Str $savedir = (%opts<savedir> // '').Str;
    my Str $file = (%opts<file> // '').Str;
    my Str $tar = (%opts<tar> // '').Str;
    my Bool $render = ?(%opts<render> // False);
    my Bool $force = ?(%opts<force> // False);
    my %defines = %opts<defines> // {};
    my $domain = %opts<domain>;
    my $ai = %opts<ai>;
    my $llm-config = %opts<llm-config>;

    my $outdir;
    if $savedir.chars > 0 {
        $outdir = $savedir.IO;
    } else {
        $outdir = "scigen-raku-$*PID".IO;
    }
    if $outdir.e {
        die "Output directory exists: $outdir (pass --force to replace)" unless $force;
        remove-tree($outdir);
    }
    $outdir.mkdir;

    my $chosen-name = $sysname // generate-system-name(:seed($seed), :effects);
    my $rule-file = $talk ?? 'talkrules.in' !! 'scirules.in';
    my $start-rule = $start-override // ($talk ?? 'SCITALK_LATEX' !! 'SCIPAPER_LATEX');
    my $book = load-rules(
        $rule-file,
        SYSNAME => $chosen-name,
        AUTHOR_NAME => @authors,
        SCIAUTHORS => author-list(@authors),
        :overrides(%defines),
    );
    if $domain.defined {
        if $ai {
            require-llm-config($llm-config // openai-compatible-config());
            apply-domain-ai($book, $domain, $llm-config // openai-compatible-config());
        } else {
            apply-domain($book, $domain);
        }
    }
    $book.set-rule('SCI_TITLE', $title) if $title.defined;
    $book.set-rule('SCI_ABSTRACT', '\\section*{Abstract}' ~ "\n\n$abstract\n") if $abstract.defined;

    my $tex-name = 'scigen.tex';
    my $tex = generate($book, $start-rule, :$seed, :pretty);
    my $tex-path = $outdir.add($tex-name);
    $tex-path.spurt($tex);

    my $rng = DeterministicRandom.new(seed => $seed);
    materialize-figures($tex, $outdir, $chosen-name, $talk, $rng, $render);
    write-bibliography($tex, $book, $outdir, $rng);
    copy-support-files($outdir);
    $outdir.add('seed.txt').spurt(seed-string($seed, @authors));

    if $render {
        render-paper($outdir, $tex-name, :$talk);
        if $file {
            my $source = $talk ?? $outdir.add('scigen.pdf') !! $outdir.add('scigen.ps');
            copy-file($source, $file.IO) if $source.e;
        }
    }

    if $tar {
        run-or-die('tar', '-czf', $tar, '-C', $outdir.Str, '.');
    }

    $outdir;
}

sub author-list(@authors --> Str) {
    return '' unless @authors;
    return @authors[0] if @authors == 1;
    return @authors[0..*-2].join(', ') ~ ' and ' ~ @authors[*-1];
}

sub seed-string(Int $seed, @authors --> Str) {
    my $s = "seed=$seed ";
    $s ~= @authors.map({ "author=$_ " }).join;
    $s;
}

sub materialize-figures(Str:D $tex, IO::Path:D $outdir, Str:D $sysname, Bool:D $talk, DeterministicRandom:D $rng, Bool:D $render --> List) {
    my @figures;

    for $tex.lines -> $line {
        if $line ~~ /'figure=' (figure <-[,]>*) ','/ {
            my $path = $outdir.add(~$0);
            write-graph(:file($path.Str), :seed($rng.pick-index(0x7fffffff)), :color($talk), :render($render));
            @figures.push($path);
        }

        if $line ~~ /<[={]> (dia <-[,}]>*) <[,}]>/ {
            my $path = $outdir.add(~$0);
            write-diagram(:file($path.Str), :sysname($sysname), :seed($rng.pick-index(0x7fffffff)), :render($render));
            @figures.push($path);
        }

        if $line ~~ /<[={]> (<-[{]>*) '-' (talkfig <-[,}]>*) <[,}]>/ {
            my $path = $outdir.add(~$0 ~ '-' ~ ~$1);
            write-talk-figure(:file($path.Str), :type(~$0), :sysname($sysname), :seed($rng.pick-index(0x7fffffff)), :render($render));
            @figures.push($path);
        }
    }

    @figures;
}

sub write-bibliography(Str:D $tex, RuleBook:D $book, IO::Path:D $outdir, DeterministicRandom:D $rng --> IO::Path) {
    my $path = $outdir.add('scigenbibfile.bib');
    my @labels = $tex.match(/'cite:' \d+/, :g).map(*.Str).unique;
    my $bib = '';
    for @labels.kv -> $index, $label {
        my $year = 1998 + ($index % 27);
        my $title = "Generated reference for $label";
        my $author = "SCIgen Reference Group";
        $bib ~= '@article{' ~ $label ~ ",\n"
            ~ '  author = {' ~ $author ~ "},\n"
            ~ '  title = {' ~ $title ~ "},\n"
            ~ '  journal = {Journal of Generated Studies},' ~ "\n"
            ~ '  year = {' ~ $year ~ "}\n"
            ~ "}\n\n";
    }
    $path.spurt($bib);
    $path;
}

sub copy-support-files(IO::Path:D $outdir) {
    for <IEEEtran.cls IEEE.bst> -> $file {
        copy-file($file.IO, $outdir.add($file)) if $file.IO.e;
    }
}

sub write-graph(Str :$file = '', Int :$seed = 1, Bool :$color = False, Bool :$render = False --> IO::Path) is export {
    my $rng = DeterministicRandom.new(:$seed);
    my $book = load-rules('scirules.in');
    my $spec = generate($book, 'GNUPLOT', :$seed, :!pretty);
    my $out = $file ?? $file.IO !! "graph-$*PID.eps".IO;
    my $gp = $out.extension eq 'gnuplot' ?? $out !! $out.parent.add($out.basename ~ '.gnuplot');
    my $data = $out.parent.add($out.basename ~ '.dat');
    my $eps = $out.extension eq 'eps' ?? $out !! $out.parent.add($out.basename ~ '.eps');

    my @points = (^50).map({
        my $x = $_ / 5;
        my $y = ($rng.next-num * 100).round(0.001);
        "$x $y"
    });
    $data.spurt(@points.join("\n") ~ "\n");
    $gp.spurt("set terminal postscript eps " ~ ($color ?? 'color' !! '') ~ "\nset output \"{$eps.Str}\"\n$spec\nplot \"{$data.Str}\" with linespoints\n");
    if $render {
        require-tools('graph rendering', <gnuplot>);
        run-or-die('gnuplot', $gp.Str);
    }
    $out;
}

sub write-diagram(Str:D :$sysname, Str :$file = '', Int :$seed = 1, Bool :$render = False --> IO::Path) is export {
    my $rng = DeterministicRandom.new(:$seed);
    my $book = load-rules('graphviz.in', SYSNAME => $sysname);
    my $num-nodes = expand($book, 'NUM_NODES', $rng).Int;
    my $graph-type = expand($book, 'PICK_GRAPH_TYPE', $rng);
    my $label-type-index = expand($book, 'PICK_LABEL_TYPE', $rng).Int;
    my $shape-type = expand($book, 'PICK_SHAPE_TYPE', $rng);
    my @label-types = <NODE_LABEL_LET NODE_LABEL_PROG NODE_LABEL_NET NODE_LABEL_IP NODE_LABEL_HW NODE_LABEL_DEC>;
    my @edge-label-types = ('""', '""', '""', '""', '""', 'EDGE_LABEL_YESNO');
    my %dir-rule = digraph => 'DIR_LAYOUT', graph => 'UNDIR_LAYOUT';
    my %edge-op = digraph => '->', graph => '--';
    my $program = expand($book, %dir-rule{$graph-type}, $rng);
    my $num-edges = (($rng.pick-index($num-nodes max 1) + $num-nodes) min 16) max 1;

    $book.add-rule('GRAPH_DIR', $graph-type);
    $book.add-rule('NODE_LABEL', @label-types[$label-type-index]);
    $book.add-rule('EDGEOP', %edge-op{$graph-type});
    $book.add-rule('SHAPE_TYPE', $_) for $shape-type.words;
    $book.add-rule('EDGE_LABEL', @edge-label-types[$label-type-index]);
    $book.add-rule('NODES', "NODES_$num-nodes");
    $book.add-rule('EDGES', "EDGES_$num-edges");

    my $dot = expand($book, 'GRAPHVIZ', $rng);
    my $out = $file ?? $file.IO !! "diagram-$*PID.eps".IO;
    my $dot-path = $out.parent.add($out.basename ~ '.dot');
    $dot-path.spurt($dot);

    if $render {
        require-tools('diagram rendering', ($program, 'ps2epsi'));
        my $tmp = $out.parent.add($out.basename ~ '.tmp.ps');
        run-or-die($program, '-Tps', $dot-path.Str, '-o', $tmp.Str);
        run-or-die('ps2epsi', $tmp.Str, $out.Str);
    }

    $out;
}

sub write-talk-figure(Str :$file = '', Str :$type = 'network', Str :$sysname = '', Int :$seed = 1, Bool :$render = False --> IO::Path) is export {
    my $rng = DeterministicRandom.new(:$seed);
    my %types = network => 'NETWORK_DIAGRAM', anything => 'ANYTHING_DIAGRAM';
    die "Bad talk figure type: $type" unless %types{$type}:exists;

    my $book = load-rules('svg_figures.in', FIGURE_TYPE => %types{$type}, SYSNAME => $sysname);
    if $type eq 'network' {
        my $num = expand($book, 'NETWORK_NUM_COMPS', $rng).Int;
        $book.add-rule('COMPUTERS', "COMPUTERS_$num");
        $book.add-rule('LINES', 'LINE_P2P_' ~ (($rng.pick-index($num max 1) + (($num * 3 / 2).Int max 1)) min 16));
        $book.add-rule('COMPUTER_PARTNERS', 'COMPUTER_PARTNER_' ~ (($rng.pick-index($num max 1) + 1) min 10));
    }

    my $svg = expand($book, 'SVG_FIG', $rng);
    $svg = place-oldpoints($svg, $rng);
    my $out = $file ?? $file.IO !! "talkfig-$*PID.eps".IO;
    my $svg-path = $out.extension eq 'svg' ?? $out !! $out.parent.add($out.basename ~ '.svg');
    $svg-path.spurt($svg);

    if $render {
        require-tools('talk figure rendering', <inkscape convert>);
        my $png = $out.parent.add($out.basename ~ '.png');
        run-or-die('inkscape', '-z', "--export-png={$png.Str}", '-b', 'white', '-D', $svg-path.Str);
        run-or-die('convert', $png.Str, $out.Str);
    }

    $out;
}

sub place-oldpoints(Str:D $svg, DeterministicRandom:D $rng --> Str) {
    my @positions;
    my @out;
    for $svg.lines -> $line is copy {
        if $line ~~ /'x="' (\d+) '" y="' (\d+) '" width="' (\d+) 'px" height="' (\d+) 'px"'/ {
            @positions.push(($0.Int + ($2.Int div 2)) ~ ' ' ~ ($1.Int + ($3.Int div 2)));
        }
        while $line ~~ /OLDPOINT(\d*)/ {
            my $suffix = ~$0;
            my $point = @positions ?? @positions[$rng.pick-index(@positions.elems)] !! '0 0';
            my ($x, $y) = $point.words;
            my $replacement = "x$suffix=\"$x\" y$suffix=\"$y\"";
            $line ~~ s/OLDPOINT\d*/$replacement/;
        }
        @out.push($line);
    }
    @out.join("\n") ~ "\n";
}

sub serve-names(Str :$host = '127.0.0.1', Int :$port = DEFAULT-PORT, Int :$seed = 1) is export {
    my $server = IO::Socket::INET.new(:localhost($host), :localport($port), :listen);
    my $counter = 0;
    loop {
        my $client = $server.accept;
        my $request = $client.recv.trim;
        $client.print(generate-system-name(:seed($seed + $counter++)) ~ "\n");
        $client.close;
    }
}

sub render-paper(IO::Path:D $outdir, Str:D $tex-name, Bool :$talk = False) {
    my @tools = $talk ?? <latex bibtex dvips ps2pdf> !! <latex bibtex dvips>;
    require-tools('paper rendering', @tools);
    run-or-die('latex', '-interaction=nonstopmode', $tex-name, :cwd($outdir));
    run-or-die('bibtex', $tex-name.subst(/'.tex'$/, ''), :cwd($outdir));
    run-or-die('latex', '-interaction=nonstopmode', $tex-name, :cwd($outdir));
    run-or-die('latex', '-interaction=nonstopmode', $tex-name, :cwd($outdir));
    my @dvips = $talk ?? ('dvips', '-t', 'landscape', '-o', 'scigen.ps', 'scigen.dvi') !! ('dvips', '-o', 'scigen.ps', 'scigen.dvi');
    run-or-die(|@dvips, :cwd($outdir));
    run-or-die('ps2pdf', 'scigen.ps', 'scigen.pdf', :cwd($outdir)) if $talk;
}

sub require-tools(Str:D $context, *@tools) is export {
    my @flat-tools = @tools.elems == 1 && @tools[0] ~~ Positional ?? @tools[0].list !! @tools;
    my @missing = @flat-tools.grep({ !tool-available($_.Str) });
    return unless @missing;
    die "Cannot perform $context; missing required command(s): {@missing.join(', ')}";
}

sub tool-available(Str:D $tool --> Bool) is export {
    return $tool.IO.x if $tool.contains('/');

    for (%*ENV<PATH> // '').split(':') -> $dir {
        next unless $dir.chars;
        return True if $dir.IO.add($tool).x;
    }
    False;
}

sub run-or-die(*@cmd, IO::Path :$cwd?) {
    require-tools("command execution", [@cmd[0].Str]);
    my $proc = $cwd.defined ?? run(|@cmd, :$cwd) !! run(|@cmd);
    die "Command failed: {@cmd.join(' ')}" unless $proc.exitcode == 0;
}

sub copy-file(IO::Path:D $from, IO::Path:D $to) {
    $to.spurt($from.slurp(:bin), :bin);
}

sub remove-tree(IO::Path:D $path) {
    return unless $path.e;
    run-or-die('/bin/rm', '-rf', '--', $path.Str);
}
