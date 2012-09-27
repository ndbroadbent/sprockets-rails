require 'fileutils'

module Sprockets
  module Rails
    class StaticCompiler
      attr_accessor :env, :target, :paths

      def initialize(env, target, paths, options = {})
        @env = env
        @target = target
        @paths = paths
        @digest = options.fetch(:digest, true)
        @manifest = options.fetch(:manifest, true)
        @zip_files = options.delete(:zip_files) || /\.(?:css|html|js|svg|txt|xml)$/
        @clean_after_precompile = options.fetch(:clean_after_precompile, true)
        @current_source_digests = options.fetch(:source_digests, {})
        @current_asset_digests  = options.fetch(:asset_digests,  {})
        @asset_digests  = {}
        @source_digests = {}

        @nondigest_after_digest = !@digest && options.fetch(:digest_precompiled, false)
      end

      def compile
        # Only find, compile and write asset if it's sources have changed.
        env.each_logical_path(paths) do |logical_path|
          # Skip source checks if we just precompiled the digest assets,
          # and are now processing non-digest assets in the following Rake task
          if @nondigest_after_digest
            recompile = false
            sources_digest = @source_digests[logical_path] = @current_source_digests[logical_path]
          else
            sources_digest = env.unprocessed_sources_digest(logical_path)
            @source_digests[logical_path] = sources_digest

            # Recompile if digest has changed or compiled digest file is missing
            current_digest_file = @current_asset_digests[logical_path]
            recompile = sources_digest != @current_source_digests[logical_path] ||
                        !(current_digest_file &&
                          File.exists?(absolute_asset_path(current_digest_file)))
          end

          if recompile
            if asset = env.find_asset(logical_path)
              @asset_digests[logical_path] = write_asset(asset)
            end

          else
            @asset_digests[logical_path] = @current_asset_digests[logical_path]

            if @nondigest_after_digest
              copy_stripped_digest_assets(logical_path)
            else
              env.logger.debug "Not compiling #{logical_path}, sources digest has not changed (#{sources_digest[0...7]})"
            end
          end
        end

        if @manifest
          write_manifest(source_digests: @source_digests, asset_digests: @asset_digests)
          clean_up_assets_folder if @clean_after_precompile
        end

        # Store digests in Rails config. (Important if non-digest is run after primary)
        config = ::Rails.application.config
        config.assets.asset_digests  = @asset_digests
        config.assets.source_digests = @source_digests
        # Set digest_precompiled flag, so we can skip checks for non-digest compilation
        config.assets.digest_precompiled = true if @digest
      end

      def write_manifest(manifest)
        FileUtils.mkdir_p(@target)
        File.open("#{@target}/manifest.yml", 'wb') do |f|
          YAML.dump(manifest, f)
        end
      end

      def write_asset(asset)
        path_for(asset).tap do |path|
          filename = File.join(target, path)
          FileUtils.mkdir_p File.dirname(filename)
          asset.write_to(filename)
          asset.write_to("#{filename}.gz") if filename.to_s =~ @zip_files
        end
      end

      def copy_stripped_digest_assets(logical_path)
        # If compiling non-digest assets, just make a copy of the digest asset.
        known_digests = @current_asset_digests.values.map {|f| f[/([0-9a-f]{32})/, 1] }

        digest_path = @asset_digests[logical_path]
        # Remove known digests from css & js
        if absolute_asset_path(digest_path).match(/\.(js|css)$/)
          asset_content = File.read(absolute_asset_path(digest_path))
          known_digests.each do |digest|
            asset_content.gsub!("-#{digest}", '')
          end
          File.open absolute_asset_path(logical_path), 'w' do |f|
            f.write asset_content
          end
          env.logger.debug "Stripped digests and copied #{digest_path} to #{logical_path}"
        else
          # Copy binary files
          FileUtils.rm_f absolute_asset_path(logical_path)
          FileUtils.cp absolute_asset_path(digest_path), absolute_asset_path(logical_path)
          env.logger.debug "Copied #{digest_path} to #{logical_path}"
        end
      end

      # Remove all files from `config.assets.prefix` that are not found in manifest.yml
      def clean_up_assets_folder
        known_files = @asset_digests.flatten
        known_files << 'manifest.yml'
        # Recognize gzipped files
        known_files += known_files.map {|f| "#{f}.gz" }

        assets_prefix = ::Rails.application.config.assets.prefix
        assets_abs_path = File.join(::Rails.public_path, assets_prefix, '')

        Dir[File.join(assets_abs_path, "**/*")].each do |path|
          unless File.directory?(path)
            logical_path = path.sub(assets_abs_path, '')
            unless logical_path.in? known_files
              FileUtils.rm path
              env.logger.debug "Deleted old asset at public#{assets_prefix}/#{logical_path}"
            end
          end
        end

        # Remove empty directories (reversed to delete top-level empty dirs first)
        Dir[File.join(assets_abs_path, "**/*")].reverse.each do |path|
          if File.exists?(path) && File.directory?(path) && (Dir.entries(path) - %w(. ..)).empty?
            FileUtils.rmdir path
            logical_path = path.sub(assets_abs_path, '')
            env.logger.debug "Deleted empty directory at public#{assets_prefix}/#{logical_path}"
          end
        end
      end

      def path_for(asset)
        @digest ? asset.digest_path : asset.logical_path
      end

      def absolute_asset_path(path)
        File.join(::Rails.public_path, ::Rails.application.config.assets.prefix, path)
      end
    end
  end
end
