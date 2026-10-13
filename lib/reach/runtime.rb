require "rbconfig"
require "shellwords"
require "yaml"
require "json"
require "fileutils"

module Reach
  module Runtime
    TEACH_URL = "https://sven-f1l1.tail062fd2.ts.net".freeze

    module_function

    def root
      File.expand_path("../..", __dir__)
    end

    def exe_path
      File.join(root, "exe", "reach")
    end

    KIT_RUBY = %r{/runtime/([^/]+)/ruby/bin/(ruby(?:\.exe)?)\z}i

    def ruby_path
      installed = installed_kit_ruby
      return installed if installed

      own = RbConfig.ruby
      match = own.to_s.tr("\\", "/").match(KIT_RUBY)
      return own if File.file?(own.to_s) && (match.nil? || kit_inside_root?(own))

      kit_ruby_fallback(match) || own
    rescue StandardError
      RbConfig.ruby
    end

    def installed_kit_ruby
      id = Reach::RuntimeKit.current_id
      return nil unless id

      bin = File.join(Reach::Paths.runtime_dir, id, "ruby", "bin")
      %w[ruby.exe ruby].map { |name| File.join(bin, name) }.find { |candidate| File.file?(candidate) }
    rescue StandardError
      nil
    end

    def kit_inside_root?(path)
      Reach::Paths.path_within?(File.expand_path(path.to_s.tr("\\", "/")), File.expand_path(Reach::Paths.root))
    end

    def kit_ruby_fallback(match)
      return nil unless match

      candidate = File.join(Reach::Paths.runtime_dir, match[1], "ruby", "bin", match[2])
      File.file?(candidate) ? candidate : nil
    end

    def shim_path
      File.join(Reach::Paths.root, "bin", "reach")
    end

    def shim_root_path
      File.join(Reach::Paths.root, "bin", "root")
    end

    def shim_content
      shebang = "#{"#"}!/usr/bin/env ruby"
      [
        shebang,
        "root = File.read(File.join(__dir__, \"root\")).strip",
        "unless File.file?(File.join(root, \"exe\", \"reach\"))",
        "  begin",
        "    require \"json\"",
        "    state = JSON.parse(File.read(File.join(__dir__, \"..\", \"state\", \"update.json\")))",
        "    managed = File.join(__dir__, \"..\", \"plugin\")",
        "    unless File.exist?(managed)",
        "      if state[\"staged_path\"].is_a?(String) && File.directory?(state[\"staged_path\"])",
        "        File.rename(state[\"staged_path\"], managed)",
        "      elsif state[\"backup_path\"].is_a?(String) && File.directory?(state[\"backup_path\"])",
        "        File.rename(state[\"backup_path\"], managed)",
        "      end",
        "    end",
        "    if File.file?(File.join(managed, \"exe\", \"reach\"))",
        "      root = File.expand_path(managed)",
        "      File.write(File.join(__dir__, \"root\"), \"\#{root}\\n\")",
        "    end",
        "  rescue StandardError",
        "    nil",
        "  end",
        "end",
        "load File.join(root, \"exe\", \"reach\")",
        ""
      ].join("\n")
    end

    def ensure_shim!
      Reach::Paths.ensure_home!
      dir = File.dirname(shim_path)
      FileUtils.mkdir_p(dir)
      write_if_different(shim_path, shim_content)
      target = shim_root_target
      write_if_different(shim_root_path, "#{target}\n") if target
      begin
        File.chmod(0o755, shim_path)
      rescue NotImplementedError, Errno::ENOENT
        nil
      end
      nil
    rescue StandardError
      nil
    end

    def shim_root_target
      return (shim_root_replaceable? ? root : nil) if Reach::Paths.legacy_active?

      recorded = File.file?(shim_root_path) ? File.read(shim_root_path).strip : ""
      stale = !recorded.empty? && in_legacy_home?(recorded)
      if in_legacy_home?(root)
        managed = File.join(Reach::Paths.root, "plugin")
        return managed if (stale || recorded.empty?) && File.file?(File.join(managed, "exe", "reach"))

        return nil
      end
      stale || shim_root_replaceable? ? root : nil
    rescue StandardError
      nil
    end

    def shim_root_replaceable?
      recorded = File.file?(shim_root_path) ? File.read(shim_root_path).strip : ""
      return true if recorded.empty? || !File.directory?(recorded)

      version_file = File.join(recorded, "VERSION")
      return true unless File.file?(version_file)

      Gem::Version.new(File.read(version_file).strip) <= Gem::Version.new(Reach::VERSION)
    rescue StandardError
      true
    end

    def in_legacy_home?(path)
      Reach::Paths.path_within?(Reach::Paths.realish(path), Reach::Paths.realish(Reach::Paths.legacy_home))
    rescue StandardError
      false
    end

    def write_if_different(path, content)
      return if File.file?(path) && File.read(path) == content

      File.write(path, content)
    rescue StandardError
      nil
    end

    def hook_command(*args)
      parts = [ruby_path, shim_path, *args]
      if windows?
        parts.map { |part| "\"#{part}\"" }.join(" ")
      else
        parts.map { |part| Shellwords.escape(part) }.join(" ")
      end
    end

    def windows?
      RbConfig::CONFIG["host_os"].to_s =~ /mswin|mingw|cygwin/ ? true : false
    end

    def detach_group
      windows? ? { new_pgroup: true } : { pgroup: true }
    end

    CREATE_NEW_PROCESS_GROUP = 0x00000200
    CREATE_UNICODE_ENVIRONMENT = 0x00000400
    CREATE_NO_WINDOW = 0x08000000
    EXTENDED_STARTUPINFO_PRESENT = 0x00080000
    PROC_THREAD_ATTRIBUTE_HANDLE_LIST = 0x00020002
    STARTF_USESTDHANDLES = 0x00000100
    NUL_ACCESS = 0x0012019F
    LOG_ACCESS = 0x00100084
    SHARE_ALL = 0x00000007
    OPEN_EXISTING = 3
    OPEN_ALWAYS = 4
    FILE_ATTRIBUTE_NORMAL = 0x00000080

    def spawn_background(*command, out: File::NULL, err: File::NULL)
      if windows?
        pid = spawn_windowless(command, out, err)
        return pid if pid
      end
      pid = Process.spawn(*command, { in: File::NULL, out: out, err: err }.merge(detach_group))
      Process.detach(pid)
      pid
    end

    def spawn_windowless(command, out = File::NULL, err = File::NULL)
      env = command.first.is_a?(Hash) ? command.first : nil
      argv = (env ? command.drop(1) : command).map(&:to_s)
      log = windowless_log(out, err)
      return nil if argv.empty? || log == false

      api = windows_api
      return nil unless api

      inherit = windows_handle_attributes
      nul = api[:create_file].call(wide("NUL"), NUL_ACCESS, SHARE_ALL, inherit, OPEN_EXISTING, 0, 0)
      return nil if nul <= 0

      sink = log ? api[:create_file].call(wide(log.tr("/", "\\")), LOG_ACCESS, SHARE_ALL, inherit, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0) : nul
      list = nil
      begin
        return nil if sink <= 0

        list = windows_handle_list(api, [nul, sink].uniq)
        return nil unless list

        program = argv.first.tr("/", "\\")
        info = "\0".b * (Fiddle::SIZEOF_VOIDP * 2 + 8)
        flags = CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP | EXTENDED_STARTUPINFO_PRESENT | (env ? CREATE_UNICODE_ENVIRONMENT : 0)
        block = env ? windows_environment(env) : nil
        ok = api[:create_process].call(File.file?(program) ? wide(program) : nil, wide(windows_command_line(argv)), nil, nil, 1, flags, block, nil,
                                       windows_startup_info(nul, sink, list.first), info)
        return nil if ok.zero?

        process, thread, pid = info.unpack("JJL")
        api[:close].call(process)
        api[:close].call(thread)
        pid
      ensure
        api[:attribute_delete].call(list.first) if list
        api[:close].call(sink) if log && sink > 0
        api[:close].call(nul)
      end
    rescue StandardError, LoadError, ScriptError
      nil
    end

    def windowless_log(out, err)
      return nil if out == File::NULL && err == File::NULL

      path = out.is_a?(Array) && out[1].to_s == "a" ? out[0] : nil
      path && (err == [:child, :out] || err == out) ? path.to_s : false
    end

    def windows_command_line(argv)
      argv.each_with_index.map do |arg, index|
        text = index.zero? ? arg.tr("/", "\\") : arg
        next text unless text.empty? || text =~ /[\s"']/

        escaped = text.gsub(/(\\*)"/) { "#{Regexp.last_match(1) * 2}\\\"" }
        escaped = escaped.sub(/(\\+)\z/) { Regexp.last_match(1) * 2 }
        "\"#{escaped}\""
      end.join(" ")
    end

    def windows_environment(env)
      merged = ENV.to_h
      env.each do |name, value|
        merged.delete_if { |key, _| key.casecmp(name.to_s).zero? }
        merged[name.to_s] = value.to_s unless value.nil?
      end
      "#{merged.sort_by { |key, _| key.upcase }.map { |key, value| "#{key}=#{value}\0" }.join}\0".encode(Encoding::UTF_16LE).b
    end

    def windows_handle_list(api, handles)
      size = "\0".b * Fiddle::SIZEOF_VOIDP
      api[:attribute_init].call(nil, 1, 0, size)
      bytes = size.unpack("J").first
      return nil if bytes.zero?

      list = Fiddle::Pointer.malloc(bytes, Fiddle::RUBY_FREE)
      return nil if api[:attribute_init].call(list, 1, 0, size).zero?

      packed = handles.pack("J*")
      values = Fiddle::Pointer.malloc(packed.bytesize, Fiddle::RUBY_FREE)
      values[0, packed.bytesize] = packed
      return [list, values] unless api[:attribute_update].call(list, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST, values, packed.bytesize, nil, nil).zero?

      api[:attribute_delete].call(list)
      nil
    end

    def windows_startup_info(input, output, attributes)
      pointer = Fiddle::SIZEOF_VOIDP
      template = pointer == 8 ? "Lx4JJJL8SSx4JJJJJ" : "LJJJL8SSJJJJJ"
      size = pointer == 8 ? 112 : 72
      [size, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, STARTF_USESTDHANDLES, 0, 0, 0, input, output, output, attributes.to_i].pack(template)
    end

    def windows_handle_attributes
      pointer = Fiddle::SIZEOF_VOIDP
      pointer == 8 ? [24, 0, 1].pack("Lx4JLx4") : [12, 0, 1].pack("LJL")
    end

    def wide(text)
      "#{text}\0".encode(Encoding::UTF_16LE).b
    end

    def windows_console?
      api = windows_api
      api ? !api[:console_cp].call.zero? : nil
    rescue StandardError
      nil
    end

    def windows_free_bytes(path)
      api = windows_api
      return nil unless api

      free = "\0".b * 8
      ok = api[:free_space].call(wide(path.to_s.tr("/", "\\")), free, nil, nil)
      ok.zero? ? nil : free.unpack("Q").first
    rescue StandardError
      nil
    end

    def windows_api
      return @windows_api if defined?(@windows_api)

      @windows_api = begin
        require "fiddle"
        kernel = Fiddle.dlopen("kernel32.dll")
        call = Fiddle::SIZEOF_VOIDP == 4 && defined?(Fiddle::Function::STDCALL) ? Fiddle::Function::STDCALL : Fiddle::Function::DEFAULT
        pointer = Fiddle::TYPE_VOIDP
        handle = Fiddle::TYPE_INTPTR_T
        int = Fiddle::TYPE_INT
        {
          create_file: Fiddle::Function.new(kernel["CreateFileW"], [pointer, int, int, pointer, int, int, handle], handle, call),
          create_process: Fiddle::Function.new(kernel["CreateProcessW"], [pointer, pointer, pointer, pointer, int, int, pointer, pointer, pointer, pointer], int, call),
          close: Fiddle::Function.new(kernel["CloseHandle"], [handle], int, call),
          console_cp: Fiddle::Function.new(kernel["GetConsoleCP"], [], int, call),
          free_space: Fiddle::Function.new(kernel["GetDiskFreeSpaceExW"], [pointer, pointer, pointer, pointer], int, call),
          attribute_init: Fiddle::Function.new(kernel["InitializeProcThreadAttributeList"], [pointer, int, int, pointer], int, call),
          attribute_update: Fiddle::Function.new(kernel["UpdateProcThreadAttribute"], [pointer, int, handle, pointer, Fiddle::TYPE_SIZE_T, pointer, pointer], int, call),
          attribute_delete: Fiddle::Function.new(kernel["DeleteProcThreadAttributeList"], [pointer], Fiddle::TYPE_VOID, call)
        }
      rescue StandardError, LoadError, ScriptError
        nil
      end
    end

    def default_teach_url
      value = ENV["REACH_TEACH_URL"]
      return value if value && !value.empty?

      configured_teach_url || baked_teach_url || TEACH_URL
    rescue StandardError
      TEACH_URL
    end

    def configured_teach_url
      config = load_config
      teach = config["teach"] if config.is_a?(Hash)
      url = teach["url"] if teach.is_a?(Hash)
      url && !url.to_s.empty? ? url.to_s : nil
    end

    def baked_teach_url
      path = Reach::Paths.teach_url_file
      return nil unless File.file?(path)

      data = JSON.parse(File.read(path))
      url = data["url"] if data.is_a?(Hash)
      url && !url.to_s.empty? ? url.to_s : nil
    rescue StandardError
      nil
    end

    def bake_teach_url!
      url = configured_teach_url
      return nil unless url

      path = Reach::Paths.teach_url_file
      FileUtils.mkdir_p(File.dirname(path))
      write_if_different(path, "#{JSON.generate('url' => url)}\n")
      url
    rescue StandardError
      nil
    end

    def load_config
      path = File.join(root, "config.yml")
      return {} unless File.file?(path)

      YAML.safe_load(File.read(path)) || {}
    rescue StandardError
      {}
    end
  end
end
