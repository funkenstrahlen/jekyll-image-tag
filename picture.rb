# Title: Jekyll Picture
# Authors:
# Download:
# Documentation:
#
# Syntax:
# Example:
# Output:

### ruby 1.9+

require 'fileutils'
require 'mini_magick'
require 'digest/md5'
require 'pathname'

module Jekyll

  class Picture < Liquid::Tag

    def initialize(tag_name, markup, tokens)

      tag = /^(?:(?<preset>[^\s.:]+)\s+)?(?<image_src>[^\s]+\.[a-zA-Z0-9]{3,4})\s*(?<source_src>(?:(source_[^\s:]+:\s+[^\s]+\.[a-zA-Z0-9]{3,4})\s*)+)?(?<html_attr>[\s\S]+)?$/.match(markup)

      raise "A picture tag is formatted incorrectly. Try {% picture [preset] path/to/img.jpg [source_key: path/to/alt-img.jpg] [attr=\"value\"] %}." unless tag

      @preset = tag[:preset] || 'default'
      @image_src = tag[:image_src]
      @source_src = if tag[:source_src]
        Hash[ *tag[:source_src].gsub(/:/, '').split ]
      else
        {}
      end
      @html_attr = if tag[:html_attr]
        Hash[ *tag[:html_attr].scan(/(?<attr>[^\s="]+)(?:="(?<value>[^"]+)")?\s?/).flatten ]
      else
        {}
      end

      super
    end

    def render(context)

      # Gather settings
      site = context.registers[:site]
      settings = site.config['picture']
      site_path = site.source
      markup = settings['markup'] || 'picturefill'
      asset_path = settings['asset_path'] || '.'
      gen_path = settings['generated_path'] || File.join(asset_path, 'generated')

      # Deep copy preset to sources for single instance manipulation
      sources = Marshal.load(Marshal.dump(settings['presets'][@preset]))

      # Process html attributes
      html_attr = if  sources['attr']
        sources.delete('attr').merge!(@html_attr)
      else
        @html_attr
      end

      if markup == 'picturefill'
        html_attr['data-picture'] = nil
        html_attr['data-alt'] = html_attr.delete('alt')
      end

      html_attr_string = ''
      html_attr.each { |key, value|
        if value
          html_attr_string += "#{key}=\"#{value}\" "
        else
          html_attr_string += "#{key} "
        end
      }

      # Prepare ppi variables
      ppi = if sources['ppi'] then sources.delete('ppi').sort.reverse else nil end
      ppi_sources = {}

      # Store source keys in an array for ordering the sources object
      source_keys = sources.keys

      # Raise some exceptions before we start expensive processing
      raise "You've specified a preset that doesn't exist." unless settings['presets'][@preset]
      raise "You're trying to specify an image for a source that doesn't exist. Please check picture: presets: #{@preset} in your _config.yml for the list of available sources." unless (@source_src.keys - source_keys).empty?

      # Process sources
      # Add image paths for each source
      sources.each_key { |key|
        sources[key][:src] = @source_src[key] || @image_src
      }

      # Construct ppi sources
      # Generates -webkit-device-ratio and resolution: dpi media value for cross browser support
      # http://www.brettjankord.com/2012/11/28/cross-browser-retinahigh-resolution-media-queries/
      if ppi
        sources.each { |key, value|
          ppi.each { |p|
            if p != 1
              ppi_key = "#{key}-x#{p}"

              ppi_sources[ppi_key] = {
                'width' => if value['width'] then (value['width'].to_f * p).round else nil end,
                'height' => if value['height'] then (value['height'].to_f * p).round else nil end,
                'media' => if value['media']
                  "#{value['media']} and (-webkit-min-device-pixel-ratio: #{p}), #{value['media']} and (min-resolution: #{(p * 96).round}dpi)"
                else
                  "(-webkit-min-device-pixel-ratio: #{p}), (min-resolution: #{(p * 96).to_i}dpi)"
                end,
                :src => value[:src]
              }

              # Add ppi_key to the source keys order
              source_keys.insert(source_keys.index(key), ppi_key)
            end
          }
        }
        sources.merge!(ppi_sources)
      end

      # Generate resized images
      sources.each { |key, source|
        sources[key][:generated_src] = generate_image(source, site_path, asset_path, gen_path)
      }

      # Construct and return tag
      if settings['markup'] == 'picturefill'

        source_tags = ''
        source_keys.each { |source|
          media = if sources[source]['media'] then " data-media=\"#{sources[source]['media']}\"" end
          source_tags += "<span data-src=\"#{sources[source][:generated_src]}\"#{media}></span>\n"
        }

        # Note: we can't indent html output because markdown parsers will turn 4 spaces into code blocks
        picture_tag = "<span #{html_attr_string}>\n"\
                      "#{source_tags}\n"\
                      "<noscript>\n"\
                      "<img src=\"#{sources['source_default'][:generated_src]}\" alt=\"#{html_attr['data-alt']}\">\n"\
                      "</noscript>\n"\
                      "</span>\n"

      elsif settings['markup'] == 'picture'

        source_tags = ''
        source_keys.each { |source|
          media = if sources[source]['media'] then " media=\"#{sources[source]['media']}\"" end
          source_tags += "<source src=\"#{sources[source][:generated_src]}\"#{media}>\n"
        }

        # Note: we can't indent html output because markdown parsers will turn 4 spaces into code blocks
        picture_tag = "<picture #{html_attr_string}>\n"\
                      "#{source_tags}\n"\
                      "<p>#{html_attr['alt']}></p>\n"\
                      "</picture>\n"
      end

        # Return the markup!
        picture_tag
    end

    def generate_image(source, site_path, asset_path, gen_path)

      raise "Source keys must have at least one of width and height in the _config.yml." unless source['width'] || source['height']

      src_image = MiniMagick::Image.open(File.join(site_path, asset_path, source[:src]))
      src_digest = Digest::MD5.hexdigest(src_image.to_blob).slice!(0..5)
      src_width = src_image[:width].to_f
      src_height = src_image[:height].to_f
      src_ratio = src_width/src_height
      src_dir = File.dirname(source[:src])
      ext = File.extname(source[:src])
      src_name = File.basename(source[:src], ext)

      gen_width = if source['width'] then source['width'].to_f else src_ratio * source['height'].to_f end
      gen_height = if source['height'] then source['height'].to_f else source['width'].to_f / src_ratio end
      gen_ratio = gen_width/gen_height

      # Don't allow upscaling. If the image is smaller than the requested dimensions, recalculate.
      if src_image[:width] < gen_width || src_image[:height] < gen_height

        warn "Warning: #{File.join(asset_path, source[:src])} is smaller than the requested resize. \nOutputting as large as possible without upscaling.".yellow

        gen_width = if gen_ratio < src_ratio then src_height * gen_ratio else src_width end
        gen_height = if gen_ratio > src_ratio then src_width/gen_ratio else src_height end
      end

      # Get whole pixel values for naming and Minimagick transformation
      gen_width = gen_width.round
      gen_height = gen_height.round

      gen_name = "#{src_name}-#{gen_width}x#{gen_height}-#{src_digest}"
      gen_absolute_path = File.join(site_path, gen_path, src_dir, gen_name + ext)
      gen_return_path = Pathname.new(File.join('/', gen_path, src_dir, gen_name + ext)).cleanpath

      # If the file doesn't exist, generate it
      if not File.exists?(gen_absolute_path)

        # Create destination diretory if it doesn't exist
        if not File.exist?(File.join(site_path, gen_path))
          FileUtils.mkdir_p(File.join(site_path, gen_path))
        end

        # Let people know their images are being generated
        puts "Generating #{gen_return_path}"

        # Scale and crop
        src_image.combine_options do |i|
          i.resize "#{gen_width}x#{gen_height}^"
          i.gravity "center"
          i.crop "#{gen_width}x#{gen_height}+0+0"
        end
        src_image.write gen_absolute_path
      end

      # Return path for html
      gen_return_path
    end
  end
end

Liquid::Template.register_tag('picture', Jekyll::Picture)
