#!/usr/bin/env ruby

# This software is (c) 2012 Michael A. Cohen
# It is released under the simplified BSD license, which can be found at:
# http://www.opensource.org/licenses/BSD-2-Clause
# 
# This script basically gives you an object representation of a .glm to work with.
# It then outputs the object representation as a new .glm
#
# Usage:
#
# ruby glm_wrangler.rb in_file.glm out_file.glm [commands]
#
# where [commands] is a list of the methods of GLMWrangler that you'd like to run.
# You'll want to put commands that need spaces or parens in quotes.  For example:
#
# ruby glm_wrangler.rb in_file.glm out_file.glm "add_sc_solar(1000, 0.1)"
#
# If you don't specify any commands you'll get an interactive session using pry,
# in the scope of the GLMWrangler instance.  Obviously this requires pry to be
# installed ("sudo gem install pry").  You can also call for an interactive
# session explicitly by using the command "interactive" (with or without quotes).
#
# You can add your own instance methods to GLMWrangler and they will automatically
# be available as commands from the command line.

# Quirks to be aware of:
# - If an object has a property set more than once (e.g. it has more than one
#   name) only the last setting is preserved
# - If there is something after the ';' (e.g. a comment) in an attribute-setting
#   line, the stuff after the ';' will be preserved, but it won't be easy to edit
# - This script does not make an attempt to preserve the nature of the whitespace
#   in the .glm file, although it does indent sanely.  Thus, to compare to your
#   original you should use 'diff -b' which ignores whitespace changes.

require 'pry'
require 'csv'
require 'debugger'

version_pieces = RUBY_VERSION.split '.'
unless version_pieces[0] == '1' && version_pieces[1] == '9'
  raise "This script was written for use with ruby 1.9; in particular, it relies on Hash being ordered to avoid reordering the properties of your .glm objects.  You can erase this check from the script and use with other versions at your own risk."
end

class Object
  def blank?
    respond_to?(:empty?) ? empty? : !self
  end
end

class String
  def blank?
    self !~ /\S/
  end
  
  def comment?
    self =~ /^\s*\/\//
  end
end

class GLMWrangler
  VERSION = '0.1'.freeze
  OBJ_REGEX = /(^|\s+)object\s+/
  PHASES = %w[A B C]
  DATA_DIR = 'data/'
  SHARED_PATH = '../shared/'
  EXT = '.glm'
  
  # Do "the works" (parse, edit according to the given commands, sign and output)
  # on a single .glm file
  def self.process(infilename, outfilename, commands = nil)
    puts "Processing #{File.basename(infilename)}"
    wrangler = GLMWrangler.new infilename, outfilename, commands
    wrangler.parse
    wrangler.run
    wrangler.sign
    puts "Writing #{File.basename(outfilename)}"
    wrangler.write
    puts
  end

  # Batch process all the .glm files in a given directory according to the given
  # commands.  Output files go to the specified output path, with the optional
  # file_sub inserted into the file name (if it doesn't contain a '/')
  # or treated as a regex replacement (if it does contain a '/')
  def self.batch(inpath, outpath, file_sub = '', commands = nil)
    infiles = Dir.glob(File.join(inpath, '*' + EXT))
    puts "Batch processing #{infiles.length} files"
    file_sub = file_sub.split('/')
    infiles.each do |infile|
      outbasename = case file_sub.length
      when 1
        File.basename(infile, EXT) + file_sub.first + EXT
      when 2
        File.basename(infile).sub(Regexp.new(file_sub.first), file_sub.last)
      else
        File.basename(infile)
      end
      outfile = File.join(outpath, outbasename)
      process infile, outfile, commands
    end
  end

  def initialize(infilename, outfilename, commands = nil)
    @infilename = infilename
    @outfilename = outfilename
    @commands = commands
    @lines = []
  end
  
  # Parse the .glm input file into ruby objects
  def parse
    infile = File.open @infilename
    
    while l = infile.gets do    
      if l =~ OBJ_REGEX   
        obj = GLMObject.new self, dec_line: l, infile: infile
        @lines << obj
      else
        # For now anything that isn't inside an object declaration just gets
        # saved as a literal string.  We could get fancy and create classes for
        # comments, module declarations, etc. if we wanted to be able to
        # edit those in the object model.
        @lines << l
      end
    end
    
    infile.close
  end
  
  def run
    if @commands.blank?
      puts "No commands given on command line; entering interactive mode."
      interactive
    else
      @commands.each do |cmd|
        puts "- Executing command: #{cmd}"
        instance_eval cmd
      end
    end
  end
  
  # put a line after all other comments at the top of the .glm that notes
  # how the .glm was wrangled
  def sign
    first_content_i = @lines.index {|l| !l.blank? && !l.comment?}
    raise "Couldn't find any non-blank, non-comment lines in the .glm" if first_content_i.nil?
    signature1 = "// Wrangled by GLMWrangler #{VERSION} from #{@infilename} to #{@outfilename}"
    signature2 = "// by #{ENV['USERNAME'] || ENV['USER']} at #{Time.now.getlocal}"
    commands = '// Wrangler commands: ' + (@commands.blank? ? '[no commands - defaulted to interactive session]' : @commands.join(' '))
    @lines.insert first_content_i, signature1, signature2, commands, ''
  end
  
  # write out a DOT file based on the parsed objects
  def write
    outfile = File.open @outfilename, 'w'
    @lines.each {|l| outfile.puts l }
    outfile.close
  end

  def method_missing(meth, *args, &block)
    if meth.to_s =~ /^find_by_(.+)$/
      prop = $1.to_sym
      @lines.select {|l| l.is_a?(GLMObject) && l[prop] == args.first}
    else
      super # You *must* call super if you don't handle the
            # method, otherwise you'll mess up Ruby's method
            # lookup.
    end
  end
  
  # GLMWrangler methods below perform tasks that are intended to be called from
  # the command line
  def interactive
    pry
  end

  # Remove objects from the top layer of the .glm that belong to a class
  # in the class_list.  Useful for removing billdumps, etc.
  def remove_classes_from_top_layer(*class_list)
    @lines.reject! {|l| l.is_a?(GLMObject) && class_list.include?(l[:class])}
  end

  def remove_service_status_players
    players = find_by_class 'player'
    players.each {|p| @lines.delete(p) if p[:property] == 'service_status'}
  end

  def remove_extra_blanks_from_top_layer
    dupe = []
    @lines.each_index do |i|
      unless @lines[i].blank? && @lines[i-1].blank?
        dupe << @lines[i]
      end
    end
    @lines = dupe
  end

  def full_year_clock
    # Unfortunately clock is not an object in GridLAB-D so we can't do this the easy way
    # (that is, by setting a GLMObject's properties) but it's not too bad with @lines
    found_tz = found_start = found_stop = success = false
    @lines.each_with_index do |l, i|
      case l
      when /^(\s*timezone )/
        @lines[i] = $1 + "PST+8PDT;"
        found_tz = true
      when /^(\s*starttime )/
        @lines[i] = $1 + "'2011-09-25 00:00:00';"
        found_start = true
      when /^(\s*stoptime )/
        @lines[i] = $1 + "'2012-09-24 23:59:59';"
        found_stop = true
      end
      success = found_tz && found_start && found_stop
      break if success
    end
    raise "Failed to verify/update all clock settings" unless success
  end

  # Update the #includes and voltage players to find their schedules in the shared directory,
  # not the .glm's home directory
  def use_shared_path
    @lines.each_with_index do |l, i|
      if l =~ /^#include "/
        @lines[i] = l.sub '#include "', '#include "' + SHARED_PATH
      end
    end

    find_by_name('network_node').first.nested.each do |obj|
      obj[:file] = SHARED_PATH + obj[:file] if obj[:file]
    end
  end

  def use_custom_weather(region)
    region.downcase!
    loc = nil
    
    # Get the location metadata for the weather region from .csv,
    # and complain if it can't be found
    CSV.foreach(DATA_DIR + 'weather_locations.csv', headers: true, header_converters: :symbol) do |row|
      if row[:region].downcase == region
        loc = row
        break
      end
    end
    raise "Can't find location data for region #{region}" if loc.nil?

    climates = find_by_class 'climate'
    raise "I need exactly one climate object" if climates.length != 1
    climate = climates.first
    climate_i = @lines.index climate

    # Update the climate object
    climate[:name] = "\"CA-#{region.capitalize}\""
    climate[:tmyfile] = "#{SHARED_PATH}#{region}_weather_full_year.csv"
    climate[:reader] = "#{region}_csv_reader"
    climate.delete :interpolate

    # Create the csv_reader object, add the location metadata to it, and insert it into the .glm
    reader = GLMObject.new(self, {class: 'csv_reader',
                                  name: climate[:reader],
                                  filename: climate[:tmyfile]})
    # On second thought, it might be better to store the location and timezone properties
    # in the .csv itself using csv_reader's $property_name=property_value syntax,
    # but this works for now.
    loc.each {|key, val| reader[key] = val unless :region == key}
    reader[:timezone] = 'PST'
    @lines.insert(climate_i, reader, '')
  end

  # set up recorders/collectors/etc for our baseline run
  def baseline_recorders(region)
    sub_rec = find_by_class('recorder').first
    raise "Substation recorder wasn't where I expected" unless sub_rec[:parent] == 'substation_transformer'
    rec_i = @lines.index(sub_rec)

    # base any recorders we add off of the substation recorder
    file_base = sub_rec[:file][0, 13].sub('t0', "base_#{region.downcase}")
    file_base = "#{file_base[0..-2]}/#{file_base}" # Putting all recordings in a subdir named after the model
    sub_rec[:file] = file_base + 'substation_power.csv'
    interval = sub_rec[:interval]
    limit = sub_rec[:limit]

    # we don't care about the phase balance of power flow, so let's cut down on data storage
    # by just capturing the total power_in to the substation
    sub_rec[:property] = 'power_in.real,power_in.imag'

    remove_classes_from_top_layer 'recorder', 'collector', 'billdump'

    xfmr_group_rec = GLMObject.new(self, {
      class: 'group_recorder',
      file: file_base + 'xfmr_kva.csv',
      group: '"class=transformer"',
      property: 'power_in',
      complex_part: 'MAG',
      interval: interval,
      limit: limit
    })

    climate_rec = GLMObject.new(self, {
      class: 'recorder',
      file: file_base + 'climate.csv',
      parent: find_by_class('climate').first[:name],
      property: 'solar_flux,temperature,humidity,wind_speed',
      interval: interval,
      limit: limit
    })

    @lines.insert rec_i, '', sub_rec, '', xfmr_group_rec, '', climate_rec

    # adjust EOLVolt multi-recorder file destinations
    find_by_class('multi_recorder').each do |obj|
      volt_match = /EOLVolt[1-9]\.csv/.match(obj[:file])
      raise "I found a multi-recorder that doesn't appear to be an EOLVolt recorder" if volt_match.nil?
      obj[:file] = file_base + volt_match[0]
    end
  end

  def setup_baseline(region)
    full_year_clock
    use_custom_weather region
    baseline_recorders region
    remove_service_status_players
    use_shared_path
    remove_extra_blanks_from_top_layer
  end

  def rerate_dist_xfmrs(region, log_file = nil)
    # Get the overall rating for a configuration
    def config_rating(xfmr_config)
      rating = 0
      if xfmr_config[:power_rating]
        rating = xfmr_config[:power_rating].to_f
      else
        rating = PHASES.inject(0) {|sum, ph| sum += (xfmr_config["power#{ph}_rating".to_sym] || 0).to_f}
      end
      raise "Can't find a rating for #{xfmr_config[:name]}" if rating == 0
      rating
    end

    # Collect the phases that the xfmr is rated on into a string
    def config_phases(xfmr_config)
      phs = ''
      PHASES.each do |ph|
        rating = xfmr_config["power#{ph}_rating".to_sym]
        phs += ph unless rating.nil? || rating.to_f == 0
      end
      phs
    end

    # Determine if two configs are similar in all important ways except rating
    # That is, they must have the same type, voltage, and rated phases
    # (though not necessarily the exact same rating, of course)
    def similar_configs(config_a, config_b)
      return false if [:connect_type, :install_type, :primary_voltage, :secondary_voltage].any? do |prop|
        config_a[prop] != config_b[prop]
      end

      config_phases(config_a) == config_phases(config_b)
    end

    # Get the max loading for each xfmr
    max_loads = {}
    CSV.foreach(DATA_DIR + "xfmr_kva/#{File.basename(@infilename)[0,10]}#{region}_xfmr_kva.csv", headers: true) do |r|
      max_loads[r['name']] = r['max']
    end

    # Find all transformer_configurations used by "Distribution Transformers"
    # and sort them by rating.  Ignore the "load"/"CTTF" transformers added by Feeder_Generator
    # for commercial loads, since they are set up in a load-specific way
    xfmrs = find_by_groupid('Distribution_Trans').select {|xfmr| xfmr[:name] !~ /load/}
    configs = xfmrs.map {|xfmr| find_by_name(xfmr[:configuration]).first}.uniq
    configs.sort! {|a, b| config_rating(a) <=> config_rating(b)}
    # puts "Found #{configs.length} viable xfmr configurations"

    # Keep track of some things for logging purposes
    counts = Hash.new 0
    counts[:total] = xfmrs.length
    [:changed, :unchanged, :failed].each do |k|
      counts[k] = 0
    end
    undersized = Hash.new 0

    xfmrs.each do |xfmr|
      # Mark that these are the transformers where we will track aging
      xfmr[:groupid] = 'Aging_Trans'

      # Find an appropriate new transformer_configuration for this xfmr given its max load
      # from the baseline run.  The new config may be the same as the old, of course.
      max_load = max_loads[xfmr[:name]].to_f
      old_config = find_by_name(xfmr[:configuration]).first
      choices = configs.select do |candidate|
        similar_configs(candidate, old_config)
      end
      # It may be that none are big enough, in which case we just choose the last candidate
      # (which because of the sorting will be the candidate with the largest rating)
      # If there were no choices (that is, no similar configs) new_config will wind up being nil
      new_config = choices.find {|candidate| config_rating(candidate) >= max_load} || choices.last

      # Change the xfmr's config if we've found a better one,
      # and leave a note about what we've done in any case.
      old_rating = config_rating old_config
      if new_config
        if new_config == old_config
          xfmr[:comment0] = "// Transformer configuration unchanged; rated #{old_rating}kVA given a max load of #{max_load}kVA"
          counts[:unchanged] += 1
        else
          xfmr[:configuration] = new_config[:name]
          xfmr[:comment0] = "// Transformer configuration changed from t_c_#{old_config[:name] =~ /\d+$/} (#{old_rating}kVA) to #{config_rating(new_config)}kVA given a max load of #{max_load}kVA"
          counts[:changed] += 1
        end
      else
        xfmr[:comment0] = "// Could not find any appropriate configuration; leaving original with a rating of #{old_rating}kVA given a max load of #{max_load}kVA"
        counts[:failed] += 1
      end
      undersized_by = max_load - config_rating(new_config || old_config)
      if undersized_by > 0
        xfmr[:comment0] += " (Undersized by #{'%.1f' % undersized_by}kVA!)"
        undersized[xfmr[:name]] = undersized_by
      end
    end

    if log_file
      out = Hash.new 'N/A'
      out[:time] = Time.now
      out[:infile] = File.basename(@infilename)
      out[:region] = region
      out.merge! counts
      if undersized.empty?
        [:undersized, :most_undersized_id, :most_undersized_by, :avg_undersized_by].each do |k|
          out[k] = 'N/A'
        end
      else
        out[:undersized] = undersized.length
        most_undersized = undersized.max_by {|k, v| v}
        out[:most_undersized_id] = most_undersized.first
        out[:most_undersized_by] = '%.1f' % most_undersized.last
        out[:avg_undersized_by] = '%.1f' % (undersized.values.inject(:+).to_f / undersized.length)
      end
      write_headers = !File.exist?(log_file)
      CSV.open(log_file, 'a+', headers: out.keys, write_headers: write_headers) do |log_f|
        log_f << out.values
      end
    end
  end
  
  # Add Solar City generation profiles to the desired load_type until the
  # specified penetration fraction is reached.  peak_load is expected in kW.
  # Also add the players necessary to support each profile that's used.
  def add_sc_solar(penetration, region)
    base_feeder_name = File.basename(@infilename)[0, 9]
    region.downcase!

    # find the peak load of this feeder, to gauge penetration against
    peak_load = nil
    CSV.foreach(DATA_DIR + 'baseline_peak_loads.csv', :headers => true) do |row|
      peak_load = row['max_load_kw'].to_i if row['name'] == "#{base_feeder_name}_base_#{region}"
    end
    raise "Couldn't find peak load for #{base_feeder_name} in #{region}" if peak_load.nil?

    # load installation capacity values from a .csv
    # in the hash, the key is the InverterID and the value is the rated capacity in kW
    capacities = {}
    CSV.foreach(DATA_DIR + 'inverter_capacities.csv', :headers => true) do |row|
      capacities[row['SGInverter'].to_i] = row['InvCapEst'].to_f
    end

    # Load the geographic meter/profile matches for this feeder and region
    # In the hash, the key is the meter node's name and the value is the
    # profile (that is, inverter) ID
    profiles = {}
    CSV.foreach(DATA_DIR + "sc_match/#{base_feeder_name}_#{region}.csv", headers: true) do |r|
      profiles[r['node']] = r['SGInverter'].to_i
    end

    # Grab all possible target objects and shuffle them
    # Currently, "targets" just means "houses" because the taxonomy models
    # simulate commercial loads with houses.
    # Note that we use a random number generator with a fixed seed
    # so we get the same order of placement each time for any given feeder
    rng = Random.new(1)
    targets = find_by_class('house').shuffle(random: rng)

    # Place solar until we hit the desired penetration, and build players for
    # all the profiles we use.  Note that we may overshoot the desired
    # penetration by a fraction of an installation -- we don't try to match it
    # exactly
    placed = Hash.new 0
    players = {}
    until placed[:res] + placed[:comm] >= peak_load * penetration do
      target = targets.shift
      raise "Ran out of targets to add solar to" if target.nil?

      # Find the Solar City profile corresponding to this target's meter
      # FIXME: We should be looking for meters OR triplex_meters
      meter = target.first_upstream 'meter'
      # Sometimes we have to step up through the meter hierarchy to get past the "fake"
      # commercial sub-meters that Feeder_Generator adds
      while meter[:name] =~ /load/ do meter = meter.first_upstream 'meter' end
      profile = profiles[meter[:name]]
      raise "Couldn't find a profile for #{target[:name]} under #{meter[:name]}" if profile.nil?
      profile_cap = capacities[profile]

      comment = "// Solar City PV generation rated at "
      base_power = "sc_gen_#{profile}.value"

      # Scale up profile if we're installing on a commercial building
      # TODO: Do we need to scale down if we have a "big" profile on a residential home?
      scale = nil
      if target[:groupid] = 'Commercial'
        # This is borrowed from PNNL's Feeder_Generator.m
        # The idea is that a reasonable guess for a rating for a commercial system
        # is its area times 0.2 efficiency times 92.902W/sf peak insolation
        potential_cap = target[:floor_area].to_i * 0.2 * 92.902 / 1000
        scale = (potential_cap / profile_cap).round(2)
        comment += "#{'%.1f' % potential_cap}kW (scaled up from #{'%.1f' % profile_cap}kW)"
        base_power += "*#{scale}"
        placed[:comm] += potential_cap
      else
        comment += "#{'%.1f' % profile_cap}kW"
        placed[:res] += profile_cap
      end

      target.add_nested({
        :class => "ZIPload",
        :comment0 => comment,
        :groupid => "SC_zipload_solar",
        :base_power => base_power,
        :heatgain_fraction => '0.0',
        :power_pf => '1.0',
        :current_pf => '1.0',
        :impedance_pf => '1.0',
        :impedance_fraction => '0.0',
        :current_fraction => '0.0',
        :power_fraction => '1.0'
      })
      
      unless players[profile]
        player_props = {
          :class => 'player',
          :name => "sc_gen_#{profile}",
          :file => "sc_gen_#{profile}.player"
        }
        players[profile] = GLMObject.new(self, player_props)
      end
    end
    
    # insert the generated player objects after the last climate object in the file
    player_i = @lines.index(find_by_class('climate').last) + 1
    @lines.insert player_i, '', *players.values

    # log how much solar was added at the end of the file
    @lines << ''
    @lines << "// glm_wrangler.rb's add_sc_solar method added #{'%.1f' % placed[:res]}kW of residential solar"
    @lines << "// and #{'%.1f' % placed[:comm]}kW of commercial solar for a total of #{'%.1f' % (placed[:res] + placed[:comm])}kW"
    @lines << "// to reach a target penetration of #{'%.1f' % (penetration * 100)}% against a peak load of #{'%.1f' % peak_load}kW"
  end
end

# base class for any object we care about in a .glm file
# GLMObject basically just parses lines from the input file into
# a key/value in its Hash-nature
class GLMObject < Hash
  TAB = " " * 2
  
  attr_reader :nested
  
  def initialize(wrangler, props = {}, nesting_parent = nil)
    # Is there a semicolon after the closing '}' for this object?
    # Defaults to true because having a semicolon is always safe
    # but we try to remember in populate_from_file if the original file
    # doesn't use one and do the same.  Note that this could cause problems if
    # you move the object from a place in the tree where it doesn't
    # need a semicolon (i.e. at the top layer) to a place where it does
    # (i.e. inside another object)
    @semicolon = true
    @nested = []
    @wrangler = wrangler
    @nesting_parent = nesting_parent
    @trailing_junk = {}
    @class = props.delete(:class)

    # If we find the special 'properties' :dec_line and :infile, use them to
    # populate this GLMObject's properties from the file
    if (dec_line = props.delete(:dec_line)) && (infile = props.delete(:infile))
      populate_from_file dec_line, infile
    end

    props.each {|key, val| self[key] = val}
    raise "GLMObject created without a class. Props: #{props}" if @class.nil?
  end

  def [](k)
    k == :class ? @class : super
  end

  def []=(k, v)
    raise "Can't change a GLMObject's GLM class once it's created." if k == :class
    super
  end
  
  # populates this object, declared by dec_line (which is assumed to have just
  # been read from infile) with properties that follow in infile, until
  # the end of the object definition is found.  Also recursively creates
  # more GLMObjects if nested objects are found
  def populate_from_file(dec_line, infile)
    comment_count = blank_count = 0
    done = false
    
    if /^\s*(\w+\s+)?object\s+(\w+)(:\d*)?\s+{/.match(dec_line) && !$2.nil?
      @class = $2
      self[:id] = $1.strip unless $1.nil? # this will usually be nil, but some objects are named
      self[:num] = $3 unless $3.nil? # note that self[:num] will include the colon before the actual number
    end
    
    until done do
      l = infile.gets.strip
      case l
      when /^\}/
        done = true
        @semicolon = l[-1] == ';'
      when ''
        self[('blank' + blank_count.to_s).to_sym] = ''
        blank_count += 1
      when /^\/\//
        self[('comment' + comment_count.to_s).to_sym] = l
        comment_count += 1
      when GLMWrangler::OBJ_REGEX
        push_nested self.class.new(@wrangler, {dec_line: l, infile: infile}, self)
      when /^([\w.]+)\s+([^;]+);(.*)$/
        # note: there will be trouble here if a property is set to a quoted
        # string that contains a ';'
        key = $1.to_sym
        self[key] = $2
        # Preserve any non-whitespace that appeared on this line after the
        # semicolon. There's no facility for editing this trailing junk,
        # it's just preserved.
        @trailing_junk[key] = $3 unless $3.empty?
      else
        raise "Object property parser hit a line it doesn't understand: '#{l}'"
      end
    end
    self
  end
  
  def comment?; false end
  
  def add_nested(props)
    push_nested self.class.new(@wrangler, props, self)
  end
  
  def tab(level)
    TAB * level
  end
  
  def to_s(indent = 0)
    id_s = self[:id] ? self[:id] + ' ' : ''
    out = tab(indent) + id_s + 'object ' + @class + (self[:num] || '') + " {\n"
    each do |key, val|
      prop_s = key.to_s
      out += case prop_s
      when /^blank/, /^comment/  
        tab(indent + 1) + val + "\n"
      when /^object/
        val.to_s(indent + 1)
      when 'id', 'num'
        '' # these are used only in the object declaration line
      else
        tab(indent + 1) + prop_s + ' ' + val + ";#{@trailing_junk[key]} \n"
      end
    end
    out + tab(indent) + '}' + (@semicolon ? ';' : '') + "\n"
  end
  
  def upstream(allow_multiple = false)
    if @nesting_parent
      u = [@nesting_parent]
    elsif named = self[:parent] || self[:from]
      u = @wrangler.find_by_name named
    elsif self[:name]
      u = @wrangler.find_by_to(self[:name])
    end
    
    if u.nil? || u.empty?
      raise "Can't find upstream node for #{self}"
    elsif !allow_multiple && u.length > 1
      raise "Found multiple upstream nodes for #{self} but only one was requested"
    end
    
    allow_multiple ? u : u.first
  end
  
  # Find the first object of type 'klass' upstream from this object
  def first_upstream(klass)
    u = self
    loop do
      u = u.upstream
      return u if u[:class] == klass
    end
  end
  
  def downstream
    d = @nested
    if self[:name]
      d += @wrangler.find_by_parent(self[:name]) + @wrangler.find_by_from(self[:name])
    end
    d += @wrangler.find_by_name(self[:to]) if self[:to]
    d
  end
  
  # Follow all downstream branches until they hit a node of type 'klass'
  # and return the results.  Note that this means we stop going down a branch
  # when we find the *first* node of the type we're interested in.
  def first_downstream(klass)
    d = downstream
    result = []
    d.each do |obj|
      if obj[:class] == klass
        result << obj
      else
        result += obj.first_downstream(klass)
      end
    end
    result
  end
  
  private
  
  def push_nested(obj)
    self[('object' + @nested.length.to_s).to_sym] = obj
    @nested << obj
    obj
  end
  
end

# Main execution of the script.  Just grabs the parameters and tells
# GLMWrangler to do its thing
case ARGV.first
when nil
  puts "Single instance usage: ruby glm_wrangler.rb <input file> <output file> [command]..."
  puts "          Batch usage: ruby glm_wrangler.rb -b[file renaming]  <input dir> <output dir> [command]..."
  puts
  puts 'If no [file renaming] is specified in batch mode, the output file names will be'
  puts 'exactly the same as the input file names.'
  puts 'If [file renaming] is specified but does not contain a "/", it will be treated as a suffix'
  puts 'and inserted just before the extension in all output file names'
  puts 'If [file renaming] contains a "/", a regex replacement will be done to replace whatever comes'
  puts 'before the "/" with whatever comes after it'
when /^-b/
  suffix = ARGV.shift[2..-1]
  inpath = ARGV.shift
  outpath = ARGV.shift
  GLMWrangler.batch inpath, outpath, suffix, ARGV
else
  infilename = ARGV.shift
  outfilename = ARGV.shift
  GLMWrangler.process infilename, outfilename, ARGV
end
