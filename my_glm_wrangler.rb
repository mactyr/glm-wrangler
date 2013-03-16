#!/usr/bin/env ruby

# This software is (c) 2012 Michael A. Cohen
# It is released under the simplified BSD license, which can be found at:
# http://www.opensource.org/licenses/BSD-2-Clause

require_relative 'glm_wrangler'

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

class MyGLMWrangler < GLMWrangler

  DATA_DIR = 'data'
  SHARED_DIR = File.join('..', 'shared')
  AGING_GROUPID = 'Aging_Trans'
  VOLTAGE_GROUPID = 'Volt_Node'
  DAY_INTERVAL = 60 * 60 * 24

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
    # as the substation recorder
    interval = sub_rec[:interval]
    limit = sub_rec[:limit]

    # we don't care about the phase balance of power flow, so let's cut down on data storage
    # by just capturing the total power_in to the substation
    sub_rec[:property] = 'power_in.real,power_in.imag'

    remove_classes_from_top_layer 'recorder', 'collector', 'billdump'

    # Add custom baseline or sc (production run) recorders as dictated
    # by the style parameter
    recs = [sub_rec] + send(:"#{style}_recorders", file_base, interval, limit)

    # Add blank lines before each recorder
    recs = recs.inject([]) {|new_recs, rec| new_recs << '' << rec}

    @lines.insert rec_i, *recs

    # adjust EOLVolt multi-recorder file destinations
    find_by_class('multi_recorder').each do |obj|
      volt_match = /EOLVolt[1-9]\.csv/.match(obj[:file])
      raise "I found a multi-recorder that doesn't appear to be an EOLVolt recorder" if volt_match.nil?
      obj[:file] = file_base + volt_match[0]
    end
  end

  def common_setup(region)
    full_year_clock
    use_custom_weather region
    remove_service_status_players
    use_shared_path
  end

  def setup_baseline(region)
    common_setup region
    setup_recorders :baseline, region
    remove_extra_blanks_from_top_layer
  end

  def setup_sc(region, penetration)
    common_setup region
    setup_recorders :sc, region
    rerate_dist_xfmrs region, 'setup_sc_xfmr_rerate_log.csv'
    add_sc_solar region, penetration
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
  def add_sc_solar(region, penetration)
    return if penetration == 0
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

    # Load the geographic meter/profile matches for this feeder and region
    # In the hash, the key is the meter node's name and the value is the
    # profile (that is, inverter) ID
    profiles = {}
    CSV.foreach(data_file("sc_match/#{base_feeder_name}_#{region}.csv"), headers: true) do |r|
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
      meter = target.location_meter
      profile = profiles[meter[:name]]
      raise "Couldn't find a profile for #{target[:name]} under #{meter[:name]}" if profile.nil?
      profile_cap = capacities[profile]

      comment = "// Solar City PV generation rated at "
      base_power = "sc_gen_#{profile}.value"

      # Scale profile if it's not an appropriate size for the target "house".
      # This formula borrowed from PNNL's Feeder_Generator.m
      # The idea is that a reasonable guess for a rating for a system
      # is its area times 0.2 efficiency times 92.902W/sf peak insolation
      # TODO: This may be too generous for residential; need to check
      potential_cap = target[:floor_area].to_i * 0.2 * 92.902 / 1000
      scale = (potential_cap / profile_cap).round(2)
      scale_down = scale < 1
      comm_res = target[:groupid] == 'Commercial' ? :comm : :res
      # We always scale for commercial, but only scale down for residential
      # (undersized systems on residential are common in real life)
      if comm_res == :comm || scale_down
        comment += "#{'%.1f' % potential_cap}kW (scaled #{scale_down ? 'down' : 'up'} from #{'%.1f' % profile_cap}kW)"
        base_power += "*#{scale}"
        placed[comm_res] += potential_cap
      else
        comment += "#{'%.1f' % profile_cap}kW"
        placed[comm_res] += profile_cap
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
          :file => File.join(SHARED_DIR, 'sc_gen', "sc_gen_#{profile}.csv")
        }
        players[profile] = new_obj player_props
      end
    end
    
    # insert the generated player objects after the last climate object in the file
    player_i = @lines.index(find_by_class('climate').last) + 1
    @lines.insert player_i, '', *players.values

    # log how much solar was added at the end of the file
    @lines << ''
    @lines << "// #{self.class}::#{__method__} added #{'%.1f' % placed[:res]}kW of residential solar"
    @lines << "// and #{'%.1f' % placed[:comm]}kW of commercial solar for a total of #{'%.1f' % (placed[:res] + placed[:comm])}kW"
    @lines << "// to reach a target penetration of #{'%.1f' % (penetration * 100)}% against a peak load of #{peak_load}kW"
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

  # Assuming that you had recorders set up according to the standard
  # MyGLMWrangler convention (that is, writing to a folder named after
  # the file) this will update the recorder destination directory and
  # filenames to the new name of the file
  def redirect_recorders(in_base = nil, out_base = nil)
    in_base ||= File.basename @infilename, EXT
    out_base ||= File.basename @outfilename, EXT
    find_by_class(['recorder', 'collector', 'multi_recorder', 'group_recorder', 'fault_check']).each do |r|
      prop = r[:class] == 'fault_check' ? :output_filename : :file
      r[prop].gsub! in_base, out_base
    end
  end

  private
  # These are private because they're helper methods that return GLMObjects
  # or Arrays of objects, and wouldn't make sense to call from the cli

  def fault_check(file_base)
    new_obj({
      class: 'fault_check',
      check_mode: 'ONCHANGE',
      output_filename: file_base + 'fault.txt'
    })
  end

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

    # Fault check
    recs << fault_check(file_base)
  end

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
          property: 'sum(power_losses.real)',
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

    # Tap-change recorders.  Here again, we only care about the final total,
    # so we'll just record once per day
    find_by_class('regulator').each do |reg|
      recs << new_obj({
        class: 'recorder',
        parent: reg[:name],
        property: 'tap_A_change_count,tap_B_change_count,tap_C_change_count',
        interval: DAY_INTERVAL,
        limit: limit,
        file: file_base + reg[:name][-5..-1] + '.csv'
      })
    end

    # Setup groupid for nodes where we want to record voltages
    # (which is any node that is a parent of a "real" transformer)
    xfmrs = find_by_class('transformer').select {|t| t.real? && !t.substation?}
    xfmrs.map {|t| t.upstream}.uniq.each do |node|
      raise "Node #{node[:name]} already has groupid #{node[:groudid]}" if node[:groupid]
      node[:groupid] = VOLTAGE_GROUPID
    end

    PHASES.each do |ph|
      recs << new_obj({
        class: 'group_recorder',
        group: "\"groupid=#{VOLTAGE_GROUPID}\"",
        property: "voltage_#{ph}",
        complex_part: 'MAG',
        interval: interval,
        limit: limit,
        file: file_base + 'v_profile_' + ph + '.csv'
      })
    end

    recs << fault_check(file_base)
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