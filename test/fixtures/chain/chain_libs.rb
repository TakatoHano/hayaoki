# 他のライブラリが require を上書きするやり方の模造。呼出回数を $chain_calls に数える。
$chain_calls = Hash.new(0)

module ChainLibs
  def self.note(lib, path)
    $chain_calls[[lib, File.basename(path.to_s, ".rb")]] += 1
  end

  # bundled_gems.rb の replace_require 相当 (instance と singleton の両方に define_method し、配線が交差する)
  def self.bundled_gems_like
    [::Kernel.singleton_class, ::Kernel].each do |kernel_class|
      kernel_class.send(:alias_method, :no_warning_require, :require)
      kernel_class.send(:define_method, :require) do |name|
        ChainLibs.note(:bundled_gems, name)
        kernel_class.send(:no_warning_require, name)
      end
      kernel_class.send(:public, :require) if kernel_class == ::Kernel.singleton_class
    end
    ::Kernel.send(:private, :require)
  end

  # bootsnap の kernel_require.rb 相当 (Kernel#require のみ。解決した絶対パスで呼ぶ)
  def self.bootsnap_like
    ::Kernel.module_eval do
      alias_method :require_without_bootsnap, :require
      alias_method :require, :require
      def require(path)
        ChainLibs.note(:bootsnap, path)
        path = File.join(__dir__, "#{path}.rb") if path.to_s.start_with?("chain_")
        require_without_bootsnap(path)
      end
      private :require
    end
  end

  # Zeitwerk の core_ext/kernel.rb 相当 (instance と singleton の両方を alias chain)
  def self.zeitwerk_like
    [::Kernel, ::Kernel.singleton_class].each do |k|
      k.class_eval do
        alias_method :zeitwerk_original_require, :require
        alias_method :require, :require
        def require(path)
          ChainLibs.note(:zeitwerk, path)
          zeitwerk_original_require(path)
        end
      end
    end
    ::Kernel.send(:private, :require)
  end

  # 後から Kernel に prepend するライブラリ
  def self.prepend_like
    hook = Module.new do
      def require(path)
        ChainLibs.note(:prepend, path)
        super
      end
    end
    ::Kernel.prepend(hook)
    ::Kernel.singleton_class.prepend(hook)
  end

  def self.install_real_order
    bundled_gems_like
    bootsnap_like
    zeitwerk_like
  end

  def self.report
    $chain_calls.sort_by { |k, _| k.map(&:to_s) }.each { |(lib, name), n| puts "#{lib} #{name} #{n}" }
  end
end
