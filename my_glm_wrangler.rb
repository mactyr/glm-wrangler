#!/usr/bin/env ruby

# This software is (c) 2012 Michael A. Cohen
# It is released under the simplified BSD license, which can be found at:
# http://www.opensource.org/licenses/BSD-2-Clause

require_relative 'glm_wrangler'
require 'date'

class Array
  # Returns the object in the middle of the array when sorted with &block
  # If the array has an even number of elements, returns the first of the middle two
  def mid_by(&block)
    length <= 2 ? first : sort_by(&block)[length / 2]
  end
end

class Numeric
  def near?(other, tolerance = 1)
    (self - other.to_f).abs <= tolerance
  end
end

class Hash
  # Convenience methods borrowed from Rails ActiveSupport
  def reverse_merge(other_hash)
    other_hash.merge(self)
  end

  def reverse_merge!(other_hash)
    # right wins if there is no left
    merge!( other_hash ){|key,left,right| left }
  end
end

class MyGLMWrangler < GLMWrangler

  DATA_DIR = 'data'
  SHARED_DIR = File.join('..', 'shared')
  AGING_GROUPID = 'Aging_Trans'
  SC_GROUPID = 'SC_zipload_solar'
  SC_CONTROL_MODE = 'SOLAR_CITY'
  DAY_INTERVAL = 60 * 60 * 24
  MINUTE_INTERVAL = 60

  # generate a "menu" of unique transformer_configurations in standard sizes
  # from a folder of .glm objects.
  def self.xfmr_config_menu(inpath, outfilename)
    infiles = glms_in_path inpath
    puts "Generating transformer_configuration menu from #{infiles.length} files"
    all_configs = []
    infiles.each do |f|
      in_wrangler = new infilename: f
      all_configs += in_wrangler.find_by_class('transformer_configuration')
    end

    # Pare down the list of all configs found to just the "standard" ones we can use
    all_configs.select! {|tc| tc.real? && tc.standard_size?}
    all_configs.each {|tc| tc.standardize_rating!}

    # If we're scrounging original taxonomy feeders (as opposed to Feeder_Generator.m
    # "loaded" feeders) then they'll have id numbers rather than names, which we'll
    # need to fix.
    all_configs.each do |tc|
      if tc[:num]
        tc[:name] = "#{tc[:class]}_#{tc[:num]}"
        tc.delete :num
      end
    end

    # Turns out that the taxonomy feeders reuse id numbers between them, so we need to
    # create out own set of unique id numbers for the menu.  We do this by prefixing
    # each config's index in the array with the letter "i" for "import"
    # We overwrite the old id number since it's not unique anyway
    all_configs.each_with_index do |tc, i|
      tc[:name].sub! /\d+$/, "i#{i+1}"
    end

    # This will output a .csv table listing all the configs on the menu; useful for debugging
    # CSV.open('xfmr_table.csv', 'w') do |f|
    #   all_configs.each do |tc|
    #     f << [tc[:name], tc.rating, tc.per_phase_rating, tc[:primary_voltage], tc[:secondary_voltage], tc[:resistance], tc[:reactance], tc[:connect_type], tc[:install_type], tc.phases]
    #   end
    # end

    puts "Writing #{all_configs.length} configurations"
    out_wrangler = new outfilename: outfilename, lines: all_configs
    out_wrangler.sign "#{self}::#{__method__}(#{inpath}, #{outfilename})"
    out_wrangler.write
  end

  # Outputs a .csv with the name, phase(s) and distance from substation
  # of each GLMObject with a :class of klass
  def self.phase_and_distance_list(infilename, outfilename, klass)
    wrangler = new infilename: infilename
    CSV.open(outfilename, 'w') do |csv|
      csv << %w[name phase distance_ft distance_mi]
      wrangler.find_by_class(klass).each do |obj|
        d = obj.distance
        csv << [obj.label, obj.simple_phases, d, d/5280]
      end
    end
  end

  # Setup batches of models with Solar City solar generation for run
  # on the cluster.
  # :indir is the directory with base models created by Feeder_Generator.m
  # (with subdirs for the climate region loaded)
  # :outdir is the destination directory (which will have one subdir created
  # per feeder)
  # :locations and :penetrations are pretty self-explanatory from the defaults
  # :use_feeders is a list of feeder IDs to use (default is all R1 & R3)
  # :skip_feeders is a list of IDs of any feeders to skip (e.g. 'R3_1247_3')
  # :adjustments is a hash of adjustments to pass through to add_sc_solar_and_storage
  # :test will prevent the models from actually being generated if set to
  # something truthy
  # :mpirun will parallelize the model generation using the mpirun shell command
  def self.sc_cluster_batch(options = {})
    # options are likely to be coming from the command line, so need to be parsed
    options = eval(options) if options.is_a? String
    raise "#{__method__} expects options in a string representation of a Hash" unless options.is_a? Hash
    options.reverse_merge! ({
      indir: '../sc_models/from_feeder_generator',
      outdir: '../sc_models',
      locations: %w[berkeley loyola sacramento],
      solar_pens: [0, 0.075, 0.15, 0.3, 0.5, 0.75, 1],
      storage_pens: [0, 0.075, 0.15, 0.3, 0.5, 0.75, 1],
      use_feeders: %w[R1_1247_1 R1_1247_2 R1_1247_3 R1_1247_4 R1_2500_1 R1_1247_1 R3_1247_1 R3_1247_2 R3_1247_3],
      skip_feeders: []
    })

    [:locations, :solar_pens, :storage_pens, :use_feeders, :skip_feeders].each do |opt|
      options[opt] = options[opt].split if options[opt].is_a? String
    end
    locations = options[:locations].map {|r| r.downcase}
    feeders = options[:use_feeders] - options[:skip_feeders]

    # tag the filename with any special adjustments being made for this batch
    adj_str = ''
    if options[:adjustments]
      if options[:adjustments][:onemin]
        adj_str += '_onemin'
        adj_str += 'down' if options[:adjustments][:onemin] == :downsampled
      end
      # make sure the adjustments string says *something* if there were
      # any adjustments and the adjustments string is still blank,
      # to make sure we don't overwrite the base model names
      adj_str = '_unknown' if adj_str.empty?
    end

    mpi_args = ''

    locations.each do |loc|
      # Berkeley uses climate region 1 loadings from Feeder_Generator.m,
      # our other two locations use region 3
      source_dir = File.join(options[:indir], "region_#{loc == 'berkeley' ? '1' : '3'}")
      feeders.each do |feeder|
        infile = Dir.glob(File.join(source_dir, "#{feeder}*#{EXT}")).first
        options[:solar_pens].each do |solar_pen|
          options[:storage_pens].each do |storage_pen|
            dest = File.join(options[:outdir], feeder)
            Dir.mkdir(dest) unless File.exists?(dest)
            dest_file = File.join(dest, "#{feeder}_sc#{'%03d' % (solar_pen * 100)}_st#{'%03d' % (storage_pen * 100)}_#{loc}#{adj_str}#{EXT}")
            command = "setup_sc('#{loc}', #{solar_pen}, #{storage_pen}, #{options[:adjustments]})"
            if options[:mpirun]
              command = " -np 1 ruby #{__FILE__} #{infile} #{dest_file} \"#{command}\" :"
              puts "Adding to mpi_args: #{command}"
              mpi_args += command
            else
              puts "Processing #{infile} -> #{dest_file} with: #{command}"
              process(infile, dest_file, command) unless options[:test]
            end
          end
        end
      end
    end

    if options[:mpirun]
      final_command = "mpirun -tag-output #{mpi_args} > stdout.txt 2> stderr.txt"
      puts "Executing: #{final_command}"
      `#{final_command}` unless options[:test]
    end
  end

  def data_file(*path_parts)
    File.join DATA_DIR, *path_parts
  end

  def shared_file(*path_parts)
    File.join SHARED_DIR, *path_parts
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
    include_str = '#include "'
    include_re = Regexp.new "^#{include_str}(.*)"
    @lines.each_with_index do |l, i|
      if l =~ include_re
        @lines[i] = include_str + shared_file($1)
      end
    end

    find_by_name('network_node', 1).nested.each do |obj|
      obj[:file] = shared_file(obj[:file]) if obj[:file]
    end
  end

  def use_custom_weather(region)
    region.downcase!
    loc = nil
    
    # Get the location metadata for the weather region from .csv,
    # and complain if it can't be found
    CSV.foreach(data_file('weather_locations.csv'), headers: true, header_converters: :symbol) do |row|
      if row[:region].downcase == region
        loc = row
        break
      end
    end
    raise "Can't find location data for region #{region}" if loc.nil?

    climate = find_by_class 'climate', 1
    climate_i = @lines.index climate

    # Update the climate object
    climate[:name] = "\"CA-#{region.capitalize}\""
    climate[:tmyfile] = shared_file "#{region}_weather_full_year.csv"
    climate[:reader] = "#{region}_csv_reader"
    climate.delete :interpolate

    # Create the csv_reader object, add the location metadata to it, and insert it into the .glm
    reader = new_obj({
      class: 'csv_reader',
      name: climate[:reader],
      filename: climate[:tmyfile]
    })
    # On second thought, it might be better to store the location and timezone properties
    # in the .csv itself using csv_reader's $property_name=property_value syntax,
    # but this works for now.
    loc.each {|key, val| reader[key] = val unless :region == key}
    reader[:timezone] = 'PST'
    @lines.insert(climate_i, reader, '')
  end

  def use_fbs_solver
    i = @lines.index {|l| l =~ /^(\s*solver_method )/}
    @lines[i] = $1 + "FBS;"

    old_len = @lines.length
    @lines.delete_if do |l|
      l.respond_to?(:match) && l =~ /^\s*(NR_iteration_limit|lu_solver)/
    end
    deleted = old_len - @lines.length
    if deleted != 2
      raise "Found wrong number of NR parameters to delete (#{deleted} rather than 2)"
    end
  end

  # set up recorders/collectors/etc for our baseline run
  def setup_recorders(style, region)
    sub_rec = find_by_class('recorder').first
    raise "Substation recorder wasn't where I expected" unless sub_rec[:parent] == 'substation_transformer'
    rec_i = @lines.index(sub_rec)

    # Setup an incomplete file name for all recorders to send their output to
    # The filename puts all the output in a directory named after the model file
    # Each recorder has to complete the filename for itself, of course
    out_basename = File.basename @outfilename, EXT
    file_base = File.join out_basename, "#{out_basename}_"
    sub_rec[:file] = file_base + 'substation_power.csv'

    # default other recorders to having the same interval and limit
    # as the default substation recorder
    interval = sub_rec[:interval]
    limit = sub_rec[:limit]

    # We're most interested in the power_in to the substation transformer
    # for peak load purposes
    sub_rec[:property] = 'power_in.real,power_in.imag,power_in_A.real,power_in_A.imag,power_in_B.real,power_in_B.imag,power_in_C.real,power_in_C.imag'
    # and we're actually interested in recording it every minute to get as close
    # to the "true" peak load as possible
    sub_rec[:interval] = MINUTE_INTERVAL

    remove_classes_from_top_layer 'recorder', 'collector', 'billdump'

    # adjust EOLVolt multi-recorder file destinations
    find_by_class('multi_recorder').each do |obj|
      volt_match = /EOLVolt[1-9]\.csv/.match(obj[:file])
      raise "I found a multi-recorder that doesn't appear to be an EOLVolt recorder" if volt_match.nil?
      obj[:file] = file_base + volt_match[0]
    end

    # Add custom baseline or sc (production run) recorders as dictated
    # by the style parameter
    recs = [sub_rec] + send(:"#{style}_recorders", file_base, interval, limit)

    # Add blank lines before each recorder
    recs = recs.inject([]) {|new_recs, rec| new_recs << '' << rec}

    @lines.insert rec_i, *recs
  end

  def common_setup(region)
    full_year_clock
    use_custom_weather region
    remove_service_status_players
    use_shared_path
    use_fbs_solver
  end

  def setup_baseline(region)
    common_setup region
    setup_recorders :baseline, region
    remove_extra_blanks_from_top_layer
  end

  def setup_sc(region, solar_pen, storage_pen, options = {})
    common_setup region
    rerate_dist_xfmrs region, 'setup_sc_xfmr_rerate_log.csv'
    add_sc_solar_and_storage region, solar_pen, storage_pen, options
    custom_load_pf
    adjust_regulator_setpoints 1.03
    sc_feeder_tweaks
    setup_recorders :sc, region
    add_generators_module if storage_pen && storage_pen > 0
    remove_extra_blanks_from_top_layer
  end

  def rerate_dist_xfmrs(region, log_file = nil)
    # Get the max loading for each xfmr
    max_loads = {}
    max_load_file = data_file 'xfmr_kva', "#{File.basename(@infilename)[0,10]}#{region}_xfmr_kva.csv"
    CSV.foreach(max_load_file, headers: true) do |r|
      max_loads[r['name']] = r['max']
    end

    # Get the thermal config parameters
    thermal_load_file = data_file 'xfmr_thermal_config.csv'
    thermal_configs = Hash.new(Hash.new)
    CSV.foreach(thermal_load_file, headers: true, header_converters: :symbol) do |r|
      v = r.delete(:primary_voltage).last.to_i
      p = r.delete(:power_rating).last.to_i
      thermal_configs[v][p] = r
    end

    # The transformers using the thermal aging model specify their impedance
    # in a different way (with :no_load_loss, :full_load_loss, etc.)
    # except... that doesn't seem to work so we'll be providing our own values
    # for some of these anyway.  I'm still going to explicitly delete them
    # before setting our own values to be on the safe side.
    thermal_props_to_reject = [:resistance, :reactance, :shunt_impedance]
    # Also specify some properties we always need to add for the thermal model
    thermal_props_to_add = {coolant_type: 'MINERAL_OIL', cooling_type: 'OA'}

    # Find all transformer_configurations used by "Distribution Transformers"
    # and sort them by rating.  Ignore the "load"/"CTTF" transformers added by Feeder_Generator
    # for commercial loads, since they are set up in a load-specific way
    xfmrs = find_by_groupid('Distribution_Trans').select {|xfmr| xfmr.real?}
    imported_configs = []

    # Get the menu of usable transformer_configurations from a previously prepared menu .glm
    # (See ::xfmr_config_menu for how the file was created)
    config_file = data_file('xfmr_config_menu.glm')
    configs = self.class.new(infilename: config_file).find_by_class 'transformer_configuration'
    configs.sort_by! {|c| c.rating}

    # Keep track of some things for logging purposes
    counts = Hash.new 0
    counts[:total] = xfmrs.length
    [:changed, :unchanged, :failed, :imported, :thermal].each do |k|
      counts[k] = 0
    end
    wrongsized = {under: Hash.new(0), over: Hash.new(0)}

    climate_name = find_by_class('climate', 1)[:name]
    xfmrs.each do |xfmr|
      # Find reasonable candidate configurations for this xfmr given its baseline max_load
      max_load = max_loads[xfmr[:name]].to_f
      old_config = find_by_name(xfmr[:configuration]).first
      old_rating = old_config.rating
      new_config = nil
      choices = configs.select {|candidate| candidate.similar_to? old_config}

      if choices.empty?
        xfmr[:comment0] = "// Could not find any appropriate configuration; leaving original with a rating of #{old_rating}kVA given a max load of #{max_load}kVA"
        counts[:failed] += 1
      else
        # Find the best new rating for this xfmr (that is, the lowest rating that is larger than
        # its baseline max_load).
        # It may be that none are big enough, in which case we just choose the last candidate
        # (which because of the sorting will be the candidate with the largest rating)
        new_rating = (choices.find {|candidate| candidate.rating >= max_load} || choices.last).rating
        if new_rating == old_rating
          # The best available rating is the one it already has, so don't change anything
          xfmr[:comment0] = "// Transformer configuration unchanged; rated #{old_rating}kVA given a max load of #{max_load}kVA"
          counts[:unchanged] += 1
        else
          # There is a better rating available than the xfmr's current rating
          # Narrow down choices to just the ones that have the right rating
          choices.select! {|c| c.rating == new_rating}
          choice_names = choices.map {|c| c[:name]}
          # Find any local choices (ones native to this .glm) that are as good a match
          # as the best one we found from the menu of choices
          local_choices = find_by_class('transformer_configuration').select do |c|
            c.rating == new_rating && c.similar_to?(old_config)
          end

          # If there are any local choices, use those, otherwise "import" one from the menu
          # If there's more than one choice, we take the middle one by impedance
          if local_choices.empty?
            new_config = choices.mid_by {|c| c.impedance}
            imported_configs << new_config
            how_changed = 'via import'
            counts[:imported] += 1
          else
            new_config = local_choices.mid_by {|c| c.impedance}
            how_changed = 'locally'
          end

          # It may be that we are using a 12.47kV xfmr in place of a 12.5kV xfmr (or vice-versa)
          # in which case we want to tweak the primary voltage on the imported configuration
          # to match the local feeder's nominal voltage
          if new_config[:primary_voltage] != old_config[:primary_voltage]
            puts "Adjusting primary voltage on #{new_config[:name]} from #{new_config[:primary_voltage]} to #{old_config[:primary_voltage]}"
            new_config[:primary_voltage] = old_config[:primary_voltage]
          end

          xfmr[:configuration] = new_config[:name]
          xfmr[:comment0] = "// Transformer configuration changed #{how_changed} from #{old_config[:name]} (#{old_rating}kVA) to #{new_config.rating}kVA given a max load of #{max_load}kVA"
          counts[:changed] += 1
        end
      end

      used_config = new_config || old_config
      used_rating = used_config.rating
      undersized_by = max_load - used_rating
      if undersized_by > 0
        xfmr[:comment0] += " (Undersized by #{'%.1f' % undersized_by}kVA!)"
        wrongsized[:under][xfmr[:name]] = undersized_by
      # Count an xfmr as oversized if it is bigger than 5kVA
      # and is rated at more than twice its baseline max_load
      elsif used_rating > 5 && (oversized_by = -undersized_by) >= max_load
        xfmr[:comment0] += " (Oversized by #{'%.1f' % oversized_by}kVA!)"
        wrongsized[:over][xfmr[:name]] = oversized_by
      end

      # Use the thermal aging model for all SINGLE_PHASE_CENTER_TAPPED xfmrs we encounter
      # (the GridLAB-D thermal model only works with this type of xfmr for now)
      if used_config[:connect_type] == 'SINGLE_PHASE_CENTER_TAPPED'
        counts[:thermal] += 1

        xfmr.merge!({
          groupid: AGING_GROUPID,
          use_thermal_model: 'TRUE',
          climate: climate_name,
          aging_granularity: 300,
          aging_constant: 15000,
          percent_loss_of_life: 0
        })

        # Set the config up with the necessary aging parameters,
        # unless it was already set up
        unless used_config[:coolant_type]
          thermal_props_to_reject.each {|prop| used_config.delete prop}

          v = used_config[:primary_voltage].to_i.round(-2)
          p = used_config.rating.to_i
          used_config.merge!(thermal_configs[v][p])
          raise "Couldn't find thermal config for #{used_config[:name]}" unless used_config[:oil_volume]

          used_config.merge! thermal_props_to_add
        end
      end
    end

    # Add the imported configs to the current wrangler
    imported_configs.uniq!
    imported_configs.sort_by! {|c| c[:name]}
    last_config_i = @lines.index(find_by_class('transformer_configuration').last)
    @lines.insert last_config_i, *imported_configs

    if log_file
      out = Hash.new 'N/A'
      out[:time] = Time.now
      out[:infile] = File.basename(@infilename)
      out[:region] = region
      out.merge! counts
      wrongsized.each do |underover, hsh|
        uo = underover.to_s
        if hsh.empty?
          ["#{uo}sized", "most_#{uo}sized_id", "most_#{uo}sized_by", "avg_#{uo}sized_by"].each do |k|
            out[k] = 'N/A'
          end
        else
          out["#{uo}sized"] = hsh.length
          most_wrongsized = hsh.max_by {|k, v| v}
          out["most_#{uo}sized_id"] = most_wrongsized.first
          out["most_#{uo}sized_by"] = '%.1f' % most_wrongsized.last
          out["avg_#{uo}sized_by"] = '%.1f' % (hsh.values.inject(:+).to_f / hsh.length)
        end
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
  # Also add storage!
  def add_sc_solar_and_storage(region, solar_pen, storage_pen = 0, options = {})
    return if solar_pen == 0 && storage_pen == 0
    base_feeder_name = File.basename(@infilename)[0, 9]
    region.downcase!

    # find the peak load of this feeder, to gauge penetration against
    peak_load = nil
    CSV.foreach(data_file('baseline_peak_loads.csv'), :headers => true) do |row|
      peak_load = row['max_load_kw'].to_i if row['name'] == "#{base_feeder_name}_base_#{region}"
    end
    raise "Couldn't find peak load for #{base_feeder_name} in #{region}" if peak_load.nil?

    # load installation capacity values from a .csv
    # in the hash, the key is the InverterID and the value is the rated capacity in kW
    capacities = {}
    CSV.foreach(data_file('inverter_capacities.csv'), :headers => true) do |row|
      capacities[row['SGInverter'].to_i] = row['InvCapEst'].to_f
    end

    if options[:onemin]
      if region != "loyola"
        raise "The one-minute profile is from loyola but you asked for region '#{region}'; you should reconsider."
      end
      # If we're setting up a "one-minute solar data" sensitivity, we're only
      # using a single profile, so we set-it-and-forget-it now
      profile = 4827
      profile_cap = capacities[profile]
      profile = "#{profile}_15min" if options[:onemin] == :downsampled
    else
      # Load the geographic meter/profile matches for this feeder and region
      # In the hash, the key is the meter node's name and the value is the
      # profile (that is, inverter) ID
      profiles = {}
      CSV.foreach(data_file("sc_match/#{base_feeder_name}_#{region}.csv"), headers: true) do |r|
        profiles[r['node']] = r['SGInverter'].to_i
      end
    end

    # Grab all possible target objects and shuffle them
    # Currently, "targets" just means "houses" because the taxonomy models
    # simulate commercial loads with houses.
    # Note that we use a random number generator with a fixed seed
    # so we get the same order of placement each time for any given feeder
    rng = Random.new(1)
    targets = find_by_class('house').shuffle(random: rng)

    # Place solar until we hit the desired solar_pen, and build players for
    # all the profiles we use.  Note that we may overshoot the desired
    # solar_pen by a fraction of an installation -- we don't try to match it
    # exactly
    placed = {}
    [:solar, :storage].each {|s| placed[s] = Hash.new(0)}
    done = Hash.new
    players = {}

    begin
      target = targets.shift
      raise "Ran out of targets to add solar/storage to" if target.nil?

      unless options[:onemin]
        # Find the Solar City profile corresponding to this target's meter
        meter = target.location_meter
        profile = profiles[meter[:name]]
        raise "Couldn't find a profile for #{target[:name]} under #{meter[:name]}" if profile.nil?
        profile_cap = capacities[profile]
      end

      base_power = "sc_gen_#{profile}.value"

      # Scale profile if it's not an appropriate size for the target "house".
      # This formula borrowed from PNNL's Feeder_Generator.m
      # The idea is that a reasonable guess for a rating for a system
      # is its area times 0.2 efficiency times 92.902W/sf peak insolation
      potential_cap = target[:floor_area].to_i * 0.2 * 92.902 / 1000
      scale = (potential_cap / profile_cap).round(2)
      scale_down = scale < 1
      comm_res = target[:groupid] == 'Commercial' ? :comm : :res
      # We always scale for commercial, but only scale down for residential
      # (undersized systems on residential are common in real life)
      if comm_res == :comm || scale_down
        size_comment = "#{'%.1f' % potential_cap} kW (scaled #{scale_down ? 'down' : 'up'} from #{'%.1f' % profile_cap} kW)"
        base_power += "*#{scale}"
        capacity = potential_cap
      else
        size_comment = "#{'%.1f' % profile_cap} kW"
        capacity = profile_cap
      end

      # Add a solar site, or stop if we've hit our solar penetration target
      if placed[:solar][:res] + placed[:solar][:comm] >= peak_load * solar_pen
        done[:solar] = true
      else
        comment = "// SolarCity PV generation rated at #{size_comment}"

        target.add_nested({
          :class => "ZIPload",
          :comment0 => comment,
          :groupid => SC_GROUPID,
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
            :file => File.join(SHARED_DIR, 'sc_gen', "sc_gen_#{profile}.csv")
          }
          players[profile] = new_obj player_props
        end

        placed[:solar][comm_res] += capacity
      end # adding a solar site

      # Add a storage site, or stop if we've hit our storage penetration target
      if placed[:storage][:res] + placed[:storage][:comm] >= peak_load * storage_pen
        done[:storage] = true
      else
        meter = target.upstream
        unless meter[:class] == 'triplex_meter'
          raise "Parent of #{target[:name]} was not a triplex_meter"
        end
        if old_inverter = meter.downstream.find {|obj| obj[:class] == 'inverter'}
          # if there's already an inverter attached to this meter,
          # that means this target house is part of a multi-house commercial
          # unit under one meter. Rather than adding a second inverter
          # (which would cause two or more inverters to compete to control
          # the same meter demand) we "grow" the existing inverter.
          # (Really, we delete the old one and replace it with a bigger new
          # one because that's simpler.)
          /rated at ([0-9.]+) kW.*([0-9]+) zones/.match old_inverter[:comment0]
          new_cap = $1.to_f + capacity
          zones = $2.to_i + 1
          @lines.delete old_inverter
          inverter = new_storage meter[:name], new_cap, zones
        else
          inverter = new_storage meter[:name], capacity
        end

        # insert the inverter into the file after the house
        target_i = @lines.index target
        @lines.insert target_i, '', inverter
        placed[:storage][comm_res] += capacity
      end # adding a storage site
      
    end until done[:solar] && done[:storage]
    
    # insert the generated player objects after the last climate object in the file
    player_i = @lines.index(find_by_class('climate').last) + 1
    @lines.insert player_i, '', *players.values

    # log how much solar & storage was added at the end of the file
    @lines << ''
    @lines << "// #{self.class}::#{__method__} summary"
    @lines << "// Baseline peak load: #{peak_load} kW"
    @lines << "// Target solar penetration: #{'%.1f' % (solar_pen * 100)}%"
    @lines << "// Residential solar: #{'%.1f' % placed[:solar][:res]} kW"
    @lines << "// Commercial solar: #{'%.1f' % placed[:solar][:comm]} kW"
    @lines << "// Total solar: #{'%.1f' % (placed[:solar][:res] + placed[:solar][:comm])} kW"
    @lines << "// Target storage penetration: #{'%.1f' % (storage_pen * 100)}%"
    @lines << "// Residential storage: #{'%.1f' % placed[:storage][:res]} kW"
    @lines << "// Commercial storage: #{'%.1f' % placed[:storage][:comm]} kW"
    @lines << "// Total storage: #{'%.1f' % (placed[:storage][:res] + placed[:storage][:comm])} kW"
  end

  # Change the power factor of all ZIPloads and house HVAC loads
  def change_load_pf(new_pf, new_hvac_pf = new_pf)
    find_by_class('house').each do |h|
      h[:hvac_power_factor] = h[:fan_power_factor] = new_hvac_pf
      h.downstream.each do |d|
        if d[:class] == 'ZIPload' && d[:groupid] != 'SC_zipload_solar'
          d[:power_pf] = d[:current_pf] = d[:impedance_pf] = new_pf
        end
      end
    end
  end

  # Implement our custom load power factors for certain load types
  def custom_load_pf
    # adjusted power factors from "power factor data.xlsx"
    new_pf = {
      'pool_pump' => '0.87',
      'responsive_loads' => '0.95',
      'unresponsive_loads' => '0.95',
      'lights' => '0.90', # this is interior lighting
      'plugs' => '0.95',
      'exterior' => '0.95'
    }
    find_by_class('house').each do |h|
      # note that for the sake of performance we're assuming
      # all the ZIPloads are nested under the house
      # If they were downstream in some other way we'd need
      # to use h.downstream, which is slower
      h.nested.each do |d|
        if d[:class] == 'ZIPload'
          new_pf.each do |load_type, pf|
            if d[:base_power].include? load_type
              d[:power_pf] = d[:current_pf] = d[:impedance_pf] = pf
              break
            end
          end
        end
      end
    end
  end

  def adjust_regulator_setpoints(setpoint_pu)
    v_ll = @infilename.include?('2500') ? 24_900 : 12_470
    # .glm regulator setpoints are based on line-to-neutral voltage
    setpoint = '%.2f' % (v_ll / Math.sqrt(3) * setpoint_pu)
    find_by_class('regulator_configuration').each do |cfg|
      cfg[:band_center] = setpoint
    end
  end

  def sc_feeder_tweaks
    case @infilename
    when /R1_1247_1/
      slice_clock
    when /R1_1247_2/
      # noop
    when /R1_1247_3/
      # noop
    when /R1_1247_4/
      # noop
    when /R1_2500_1/
      cap = find_by_class 'capacitor', 1
      PHASES.each {|ph| cap[:"capacitor_#{ph}"] = '0.05 MVAr'}
    when /R3_1247_1/
      # noop
    when /R3_1247_2/
      # noop
    when /R3_1247_3/
      slice_clock 3
    end
  end

  # Assuming that your recorder paths are of the form:
  # [run_id]/[run_id]_rec_blah.csv
  # This will replace [run_id] with the basename of outfilename
  # Useful when you split out a model and want to keep the same
  # recorders but direct their output to a new dir.
  def redirect_recorders(outfilename = @outfilename)
    out_base ||= File.basename outfilename, EXT
    find_by_class(['recorder', 'collector', 'multi_recorder', 'group_recorder', 'fault_check']).each do |r|
      prop = r[:class] == 'fault_check' ? :output_filename : :file
      dirname, filename = File.split(r[prop])
      if dirname.include?(File::SEPARATOR) || !filename.start_with?(dirname)
        raise "'#{r[prop]}' isn't a recorder path I can redirect"
      end
      r[prop].gsub! dirname, out_base
    end
  end

  def slice_clock(slices = 2)
    @clock_slices = slices
  end

  def clock_sliced?
    (@clock_slices || 1) > 1
  end

  def sign
    if clock_sliced?
      note = "// Split into #{@clock_slices} time slices with filename endings like '_s?.glm'."
    end
    super @commands, note
  end

  def write
    clock_sliced? ? write_slices : super
  end

  private

  # Makes identical copies of the .glm except that the clock time is
  # divided into several identical time slices -- for doing pieces of
  # the year in parallel.
  # Note that we make the assumption that start times end in 00:00:00
  # and stop times end in 23:59:59
  # Note also that slices after the first begin a day "early" to give
  # the model time to reach a reasonable steady state (e.g. voltage
  # regulators in the right place) before we start looking at results.
  def write_slices(slices = @clock_slices, overlap_days = 1)
    raise "I don't understand how to add a slice identifier to #{@outfilename} since it doesn't end in '.glm'" if @outfilename !~ /\.glm$/
    puts "Writing #{slices} time slices to files like #{@outfilename.sub('.glm', "_s?.glm")}"

    start_i = @lines.index {|l| l =~ /starttime '(.*)'/}
    start_t = DateTime.parse($1).to_time.utc
    stop_i = @lines.index {|l| l =~ /stoptime '(.*)'/}
    stop_t = DateTime.parse($1).to_time.utc

    slice_days = ((stop_t - start_t) / DAY_INTERVAL / slices).ceil

    1.upto(slices) do |slice|
      slice_start = start_t
      if slice > 1
        slice_start += (slice_days * (slice - 1) - overlap_days) * DAY_INTERVAL
      end
      # The -1 here is -1 second, to make the end time 23:59:59
      slice_stop = start_t + slice_days * slice * DAY_INTERVAL - 1
      slice_stop = [slice_stop, stop_t].min

      @lines[start_i] = "     starttime '#{slice_start.strftime('%F %T')}';"
      @lines[stop_i] = "     stoptime '#{slice_stop.strftime('%F %T')}';"
      outf = @outfilename.sub('.glm', "_s#{slice}.glm")
      redirect_recorders outf
      File.write outf, to_s
    end
  end

  # The following are private because they're helper methods that return GLMObjects
  # or Arrays of objects, and wouldn't make sense to call from the cli

  def baseline_recorders(file_base, interval, limit)
    recs = []

    recs << new_obj({
      class: 'group_recorder',
      file: file_base + 'xfmr_kva.csv',
      group: '"class=transformer"',
      property: 'power_in',
      complex_part: 'MAG',
      interval: interval,
      limit: limit
    })

    # Climate verification recorder
    recs << new_obj({
      class: 'recorder',
      file: file_base + 'climate.csv',
      parent: find_by_class('climate').first[:name],
      property: 'solar_flux,temperature,humidity,wind_speed',
      interval: interval,
      limit: limit
    })
  end

  # Note that there is an assumption that this is called after the feeder is
  # otherwise fully set up, as it conditionally sets up some recorders
  # depending on whether the thing to be recorded is actually in the model
  def sc_recorders(file_base, interval, limit)
    recs = []

    # Real power loss recorders
    loss_types = {
      'overhead_line' => 'OHL',
      'underground_line' => 'UGL',
      'triplex_line' => 'TPL',
      'transformer' => 'TFR'
    }
    loss_types.each do |ltype, abbrev|
      # Only set up recorders for classes that actually exist in the feeder
      # (Specifically, R3_1247_2 doesn't have any triplex_lines,
      # and trying to record on class=triplex_line crashes GridLAB-D)
      if @lines.detect {|line| line.is_a?(GLMObject) && line[:class] == ltype}
        recs << new_obj({
          class: 'collector',
          group: "\"class=#{ltype}\"",
          property: 'sum(power_losses.real),sum(power_losses.imag)',
          interval: interval,
          limit: limit,
          file: file_base + abbrev + '_losses.csv'
        })
      end
    end

    # Aging_Transformer loss of life and replacements
    # All we really care about is these values at the end of the run,
    # so we'll only collect them once a day to save space
    xfmr_props = {
      'percent_loss_of_life' => 'pct_lol',
      'transformer_replacement_count' => 'replacements'
    }
    xfmr_props.each do |prop, abbrev|
      recs << new_obj({
        class: 'group_recorder',
        group: "\"groupid=#{AGING_GROUPID}\"",
        property: prop,
        interval: DAY_INTERVAL,
        limit: limit,
        file: file_base + 'xfmr_' + abbrev + '.csv'
      })
    end

    # Also collect power profiles for Aging_Transformers so we
    # can have some sense of why we're seeing what we're seeing
    recs << new_obj({
      class: 'group_recorder',
      group: "\"groupid=#{AGING_GROUPID}\"",
      property: 'power_in',
      complex_part: 'MAG',
      interval: interval,
      limit: limit,
      file: file_base + 'xfmr_va.csv'
    })

    # Tap-change recorders
    find_by_class('regulator').each do |reg|
      recs << new_obj({
        class: 'recorder',
        parent: reg[:name],
        property: 'tap_A_change_count,tap_B_change_count,tap_C_change_count,tap_A,tap_B,tap_C,power_in_A.real,power_in_A.imag,power_in_B.real,power_in_B.imag,power_in_C.real,power_in_C.imag,power_out_A.real,power_out_A.imag,power_out_B.real,power_out_B.imag,power_out_C.real,power_out_C.imag,current_in_A.real,current_in_A.imag,current_in_B.real,current_in_B.imag,current_in_C.real,current_in_C.imag,current_out_A.real,current_out_A.imag,current_out_B.real,current_out_B.imag,current_out_C.real,current_out_C.imag',
        interval: interval,
        limit: limit,
        file: file_base + reg[:name][-5..-1] + '.csv'
      })
    end

    # Record voltage at the point of use, which conveniently is always
    # a triplex_meter
    recs << new_obj({
      class: 'group_recorder',
      group: 'class=triplex_meter',
      property: "voltage_12",
      complex_part: 'MAG',
      interval: interval,
      limit: limit,
      file: file_base + 'v_profile_12.csv'
    })

    # Record total PV output, if there is any SC solar to record
    if find_by_class('house').any? {|h| h.nested.any? {|n| n[:groupid] == SC_GROUPID }}
      recs << new_obj({
        class: 'collector',
        group: "\"class=ZIPload AND groupid=#{SC_GROUPID}\"",
        property: 'sum(actual_power.real)',
        interval: MINUTE_INTERVAL,
        limit: limit,
        file: file_base + 'sc_gen.csv'
      })
    end

    # Record aggregate SC storage stats, if there's any storage
    unless find_by_four_quadrant_control_mode(SC_CONTROL_MODE).empty?
      recs << new_obj({
        class: 'collector',
        group: "\"four_quadrant_control_mode=#{SC_CONTROL_MODE}\"",
        property: 'sum(sc_dispatch_power),avg(battery_soc),std(battery_soc),min(battery_soc),max(battery_soc)',
        interval: MINUTE_INTERVAL,
        limit: limit,
        file: file_base + 'sc_storage.csv'
      })
    end

    # Record capacitor switch states, if any
    caps = find_by_class('capacitor')
    unless caps.empty?

      prop = caps.map do |cap|
        PHASES.map do |ph|
          "#{cap[:name]}:switch#{ph}"
        end
      end.flatten.join ','

      recs << new_obj({
        class: 'multi_recorder',
        property: prop,
        interval: interval,
        limit: limit,
        file: file_base + 'cap_switch.csv'
      })
    end

    recs
  end

  def add_generators_module
    tape_i = @lines.find_index {|l| l =~ /^module tape;/}
    @lines.insert tape_i, 'module generators;'
  end

  # capacity is the power transfer capacity (not energy capacity)
  def new_storage(meter_name, capacity, zones = 1)
    rate = "#{'%.1f' % capacity} kW"
    battery_cap = "#{'%.1f' % (2 * capacity)} kWh"
    p_margin = capacity < 9 ? 0.25 * capacity : Math.sqrt(capacity) - 0.75
    # Warning: it's hacky, but add_sc_solar_and_storage depends on the wording
    # of the comment below; don't change it without checking there.
    comment = "// SolarCity storage rated at #{rate} / #{battery_cap} covering #{zones} zones"

    inverter = new_obj({
      :class => 'inverter',
      :comment0 => comment,
      :name => "inv_#{meter_name}",
      :inverter_type => 'FOUR_QUADRANT',
      :four_quadrant_control_mode => SC_CONTROL_MODE,
      :parent => meter_name,
      :rated_power => "#{'%.1f' % (1.1 * capacity)} kW", # Per phase rating
      :inverter_efficiency => '0.96',
      :p_margin => "#{'%.1f' % p_margin} kW",
      # this is a wild guess, but we don't really know anything about the load,
      # just the solar system size. At worst, this value will only be used
      # until the first start-of-month target update.
      :p_target => "#{'%.1f' % (0.75 * capacity)} kW",
      :max_discharge_rate => rate,
      :max_charge_rate => rate,
      :dT_runtime => '1 h'
    })

    inverter.add_nested({
      :class => 'battery',
      :name => "batt_#{meter_name}",
      :use_internal_battery_model => 'TRUE',
      :battery_type => 'LI_ION',
      :battery_capacity => battery_cap,
      :round_trip_efficiency => '0.9',
      :state_of_charge => '1.0',
      :generator_mode => 'SUPPLY_DRIVEN'
    })

    inverter
  end
end

# Include this module for any GLMObject class that needs to be able to test
# whether it is "real" (that is whether it was part of the original taxonomy
# topology, as opposed to created by Feeder_Generator.m to serve part of
# a commercial load).
module GLMWrangler::RealTest
  def real?
    self[:name] !~ /load/
  end
end

# This module (and any module named after a GridLAB-D class in this way) will be
# added to any GLMObject with a matching @class (in this case, 'transformer_configuration').
# See GLMObject#initialize for details on how it's done.
module GLMWrangler::GLMObject::TransformerConfiguration
  include GLMWrangler::RealTest

  PHASES = GLMWrangler::PHASES
  # This is like the standard xfmr sizes from IEEE Std C57.12.20-2011 except that:
  # - We add 5, to accomodate 15kVA 3ph xfmrs and very small single-phase loads
  # - We substitute 175 for 167 and 337.5 for 333 since there are no 167 or 333kVA
  #   xfmrs in the GridLAB-D taxonomy feeders
  # - We add 750 and 1000 on the high end since we occasionally need an xfmr that big
  STD_KVA_1PH = [5, 10, 15, 25, 37.5, 50, 75, 100, 175, 250, 337.5, 500, 750, 1000]
  STD_KVA_EDITS = {175 => 167, 337.5 => 333}

  # Get the overall 3ph rating for the configuration
  def rating
    r = 0
    if self[:power_rating]
      r = self[:power_rating].to_f
    else
      r = PHASES.inject(0) {|sum, ph| sum += (self["power#{ph}_rating".to_sym] || 0).to_f}
    end
    raise "Can't find a rating for #{self[:name]}" if r == 0
    r
  end

  def per_phase_rating
    rating / phase_count
  end

  # Collect the phases that the transformer_config is rated on into a string
  def phases
    phs = ''
    PHASES.each do |ph|
      rating = self["power#{ph}_rating".to_sym]
      phs += ph unless rating.nil? || rating.to_f == 0
    end
    phs
  end

  def phase_count
    phases.length
  end

  # Determine if another config is similar in all important ways except rating
  # That is, they must have the same type, voltage, and rated phases
  def similar_to?(other)
    return false if [:connect_type, :install_type, :secondary_voltage].any? do |prop|
      self[prop] != other[prop]
    end

    # Allow 12.47kV and 12.5kV configurations to be used interchangably
    return false if (self[:primary_voltage].to_i - other[:primary_voltage].to_i).abs > 300

    self.phases == other.phases
  end

  def standard_size?
    r = per_phase_rating
    # Being loose with the matching here to account for any floating-point oddness
    STD_KVA_1PH.find {|std| std.near? r}
  end

  def impedance
    Math.sqrt(self[:resistance].to_f**2 + self[:reactance].to_f**2)
  end

  # Reclassify a 175kVA xfmr as 167kVA and 337.5kVA to 333kVA
  def standardize_rating!
    r = per_phase_rating
    STD_KVA_EDITS.each do |nonstandard, standard|
      if r.near? nonstandard
        phases.chars {|ph| self["power#{ph}_rating".to_sym] = '%.1f' % standard}
        self[:power_rating] = '%.1f' % (standard * phase_count) if self[:power_rating]
        break
      end
    end
  end
end

module GLMWrangler::GLMObject::Transformer
  include GLMWrangler::RealTest

  def substation?
    self[:name] == 'substation_transformer'
  end

  def configuration
    @wrangler.find_by_name self[:configuration], 1
  end
end

module GLMWrangler::GLMObject::Meter
  include GLMWrangler::RealTest
end

module GLMWrangler::GLMObject::TriplexMeter
  # Can't use the generic #real? here because the fake
  # triplex_meters don't always have "load" in the name
  def real?
    name = self[:name]
    name[0, 3] != 'tpm' && name !~ /load/
  end
end

module GLMWrangler::GLMObject::House
  # Find the meter that will determine this house's "location" for the purpose
  # of being assigned a Solar City generation profile.  The "meter" may also
  # be a triplex_meter.
  def location_meter
    u = upstream
    until u[:class][-5..-1] == 'meter' && u.real? do u = u.upstream; end
    raise "Hit the SWING node looking for #{self[:name]}'s location meter" if u[:bustype] == 'SWING'
    u
  end
end

# Main execution of the script.  Just grabs the parameters and tells
# GLMWrangler to do its thing
MyGLMWrangler.start_from_cli