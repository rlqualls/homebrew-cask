class Hbc::HbAbstractDownloadStrategy
  attr_reader :name, :url, :uri_object, :version

  def initialize(cask)
    @name       = cask.token
    @url        = cask.url.to_s
    @uri_object = cask.url
    @version    = cask.version
  end

  def expand_safe_system_args(args)
    args = args.dup
    args.each_with_index do |arg, ii|
      if arg.is_a? Hash
        unless Hbc.verbose
          args[ii] = arg[:quiet_flag]
        else
          args.delete_at ii
        end
        return args
      end
    end
    # 2 as default because commands are eg. svn up, git pull
    args.insert(2, '-q') unless Hbc.verbose
    args
  end

  def quiet_safe_system(*args)
    safe_system(*expand_safe_system_args(args))
  end

  # All download strategies are expected to implement these methods
  def fetch; end
  def cached_location; end
  def clear_cache; end
end

class Hbc::HbVCSDownloadStrategy < Hbc::HbAbstractDownloadStrategy
  REF_TYPES = [:branch, :revision, :revisions, :tag].freeze

  def initialize(cask)
    super
    @ref_type, @ref = extract_ref
    @clone = HOMEBREW_CACHE.join(cache_filename)
  end

  def extract_ref
    key = REF_TYPES.find do |type|
      uri_object.respond_to?(type) and uri_object.send(type)
    end
    return key, key ? uri_object.send(key) : nil
  end

  def cache_filename
    "#{name}--#{cache_tag}"
  end

  def cache_tag
    "__UNKNOWN__"
  end

  def cached_location
    @clone
  end

  def clear_cache
    cached_location.rmtree if cached_location.exist?
  end
end

class Hbc::HbCurlDownloadStrategy < Hbc::HbAbstractDownloadStrategy
  # todo should be part of url object
  def mirrors
    @mirrors ||= []
  end

  def tarball_path
    @tarball_path ||= Pathname.new("#{HOMEBREW_CACHE}/#{name}-#{version}#{ext}")
  end

  def temporary_path
    @temporary_path ||= Pathname.new("#{tarball_path}.incomplete")
  end

  def cached_location
    tarball_path
  end

  def clear_cache
    [cached_location, temporary_path].each { |f| f.unlink if f.exist? }
  end

  def downloaded_size
    temporary_path.size? or 0
  end

  # Private method, can be overridden if needed.
  def _fetch
    curl @url, '-C', downloaded_size, '-o', temporary_path
  end

  def fetch
    ohai "Downloading #{@url}"
    unless tarball_path.exist?
      had_incomplete_download = temporary_path.exist?
      begin
        _fetch
      rescue Hbc::ErrorDuringExecution
        # 33 == range not supported
        # try wiping the incomplete download and retrying once
        if $?.exitstatus == 33 && had_incomplete_download
          ohai "Trying a full download"
          temporary_path.unlink
          had_incomplete_download = false
          retry
        else
          if @url =~ %r[^file://]
            msg = "File does not exist: #{@url.sub(%r[^file://], "")}"
          else
            msg = "Download failed: #{@url}"
          end
          raise Hbc::CurlDownloadStrategyError, msg
        end
      end
      ignore_interrupts { temporary_path.rename(tarball_path) }
    else
      puts "Already downloaded: #{tarball_path}"
    end
  rescue Hbc::CurlDownloadStrategyError
    raise if mirrors.empty?
    puts "Trying a mirror..."
    @url = mirrors.shift
    retry
  else
    tarball_path
  end

  private

  def curl(*args)
    args << '--connect-timeout' << '5' unless mirrors.empty?
    super
  end

  def ext
    # We need a Pathname because we've monkeypatched extname to support double
    # extensions (e.g. tar.gz). -- todo actually that monkeypatch has been removed
    Pathname.new(@url).extname[/[^?]+/]
  end
end

# Download via an HTTP POST.
# Query parameters on the URL are converted into POST parameters
class Hbc::HbCurlPostDownloadStrategy < Hbc::HbCurlDownloadStrategy
  def _fetch
    base_url,data = @url.split('?')
    curl base_url, '-d', data, '-C', downloaded_size, '-o', temporary_path
  end
end

class Hbc::HbSubversionDownloadStrategy < Hbc::HbVCSDownloadStrategy
  def cache_tag
    # todo: pass versions as symbols, support :head here
    version == 'head' ? "svn-HEAD" : "svn"
  end

  def repo_valid?
    @clone.join(".svn").directory?
  end

  def repo_url
    `svn info '#{@clone}' 2>/dev/null`.strip[/^URL: (.+)$/, 1]
  end

  def fetch
    @url = @url.sub(/^svn\+/, '') if @url =~ %r[^svn\+http://]
    ohai "Checking out #{@url}"

    clear_cache unless @url.chomp("/") == repo_url or quiet_system 'svn', 'switch', @url, @clone

    if @clone.exist? and not repo_valid?
      puts "Removing invalid SVN repo from cache"
      clear_cache
    end

    case @ref_type
    when :revision
      fetch_repo @clone, @url, @ref
    when :revisions
      # nil is OK for main_revision, as fetch_repo will then get latest
      main_revision = @ref[:trunk]
      fetch_repo @clone, @url, main_revision, true

      get_externals do |external_name, external_url|
        fetch_repo @clone+external_name, external_url, @ref[external_name], true
      end
    else
      fetch_repo @clone, @url
    end
  end

  def shell_quote(str)
    # Oh god escaping shell args.
    # See http://notetoself.vrensk.com/2008/08/escaping-single-quotes-in-ruby-harder-than-expected/
    str.gsub(/\\|'/) { |c| "\\#{c}" }
  end

  def get_externals
    `svn propget svn:externals '#{shell_quote(@url)}'`.chomp.each_line do |line|
      name, url = line.split(/\s+/)
      yield name, url
    end
  end

  def fetch_repo(target, url, revision=nil, ignore_externals=false)
    # Use "svn up" when the repository already exists locally.
    # This saves on bandwidth and will have a similar effect to verifying the
    # cache as it will make any changes to get the right revision.
    svncommand = target.directory? ? 'up' : 'checkout'
    args = ['svn', svncommand]
    # SVN shipped with XCode 3.1.4 can't force a checkout.
    args << '--force' unless MacOS.release == :leopard
    args << url unless target.directory?
    args << target
    args << '-r' << revision if revision
    args << '--ignore-externals' if ignore_externals
    quiet_safe_system(*args)
  end
end

# Require a newer version of Subversion than 1.4.x (Leopard-provided version)
class Hbc::HbStrictSubversionDownloadStrategy < Hbc::HbSubversionDownloadStrategy
  def find_svn
    exe = `svn -print-path`
    `#{exe} --version` =~ /version (\d+\.\d+(\.\d+)*)/
    svn_version = $1
    version_tuple=svn_version.split(".").collect {|v|Integer(v)}

    if version_tuple[0] == 1 and version_tuple[1] <= 4
      onoe "Detected Subversion (#{exe}, version #{svn_version}) is too old."
      puts "Subversion 1.4.x will not export externals correctly for this formula."
      puts "You must either `brew install subversion` or set HOMEBREW_SVN to the path"
      puts "of a newer svn binary."
    end
    return exe
  end
end

# Download from SVN servers with invalid or self-signed certs
class Hbc::HbUnsafeSubversionDownloadStrategy < Hbc::HbSubversionDownloadStrategy
  def fetch_repo(target, url, revision=nil, ignore_externals=false)
    # Use "svn up" when the repository already exists locally.
    # This saves on bandwidth and will have a similar effect to verifying the
    # cache as it will make any changes to get the right revision.
    svncommand = target.directory? ? 'up' : 'checkout'
    args = ['svn', svncommand, '--non-interactive', '--trust-server-cert', '--force']
    args << url unless target.directory?
    args << target
    args << '-r' << revision if revision
    args << '--ignore-externals' if ignore_externals
    quiet_safe_system(*args)
  end
end

class Hbc::HbDownloadStrategyDetector
  def self.detect(url, strategy=nil)
    if strategy.nil?
      detect_from_url(url)
    elsif Class === strategy && strategy < Hbc::AbstractDownloadStrategy
        strategy
    elsif Symbol === strategy
      detect_from_symbol(strategy)
    else
      raise TypeError,
        "Unknown download strategy specification #{strategy.inspect}"
    end
  end

  def self.detect_from_url(url)
    case url
    when %r[^https?://(.+?\.)?googlecode\.com/svn], %r[^https?://svn\.], %r[^svn://], %r[^https?://(.+?\.)?sourceforge\.net/svnroot/]
      Hbc::HbSubversionDownloadStrategy
    when %r[^http://svn\.apache\.org/repos/], %r[^svn\+http://]
      Hbc::HbSubversionDownloadStrategy
    else
      Hbc::HbCurlDownloadStrategy
    end
  end

  def self.detect_from_symbol(symbol)
    case symbol
    when :svn     then Hbc::HbSubversionDownloadStrategy
    when :curl    then Hbc::HbCurlDownloadStrategy
    when :post    then Hbc::HbCurlPostDownloadStrategy
    else
      raise "Unknown download strategy #{strategy} was requested."
    end
  end
end
