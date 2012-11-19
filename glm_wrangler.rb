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
  INDEX_PROPS = [:name, :class, :parent, :from, :to]
  PHASES = %w[A B C]
  
  def initialize(infilename, outfilename, commands = nil)
    @infilename = infilename
    @outfilename = outfilename
    @commands = commands
    @lines = []
    @indexes = {}
    INDEX_PROPS.each do |prop|
      @indexes[prop] = Hash.new{|h,k| h[k] = []}
    end
  end
  
  # Parse the .glm input file into ruby objects
  def parse
    infile = File.open @infilename
    
    while l = infile.gets do    
      if l =~ OBJ_REGEX   
        obj = GLMObject.from_file l, infile, self
        @lines << obj
        index_obj obj
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
  
  # recursively add a GLMObject to all the indexes we're creating
  def index_obj(obj)
    INDEX_PROPS.each do |prop|
      @indexes[prop][obj[prop]] << obj if obj[prop]
    end
    obj.nested.each {|n_obj| index_obj n_obj}
  end
  
  def run
    if @commands.blank?
      puts "No commands given on command line; entering interactive mode."
      interactive
    else
      @commands.each do |cmd|
        puts "Executing command: #{cmd}"
        instance_eval cmd
      end
    end
  end
  
  # put a line after all other comments at the top of the .glm that notes
  # how the .glm was wrangled
  def sign
    first_content_i = @lines.index {|l| !l.blank? && !l.comment?}
    raise "Couldn't find any non-blank, non-comment lines in the .glm" if first_content_i.nil?
    signature = "// Wrangled by GLMWrangler #{VERSION} from #{@infilename} to #{@outfilename} by #{ENV['USERNAME'] || ENV['USER']} at #{Time.now.getlocal}"
    commands = '// Wrangler commands: ' + (@commands.blank? ? '[no commands - defaulted to interactive session]' : @commands.join(' '))
    @lines.insert first_content_i, signature, commands, ''
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
      if @indexes[prop]
        @indexes[prop][args[0]]
      else
        raise NoMethodError, "I don't know how to find by property #{$1}"
      end
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

  def derate_residential_xfmrs(factor)
    find_by_class('transformer_configuration').each do |t|
      if t[:connect_type] == 'SINGLE_PHASE_CENTER_TAPPED'
        (PHASES + ['']).each do |phase|
          prop = "power#{phase}_rating".to_sym
          if val = t[prop]
            words = val.split
            words[0] = (words[0].to_f * factor).to_s
            t[prop] = words.join ' '
          end
        end
      end
    end 
  end
  
  # Add Solar City generation profiles to the desired load_type until the
  # specified penetration fraction is reached.  peak_load is expected in kW.
  # Also add the players necessary to support each profile that's used.
  def add_sc_solar(peak_load, penetration, load_type = :residential)
    rng = Random.new 1
    
    # dummy solar profiles.  The key is the installation number and the value
    # is the rating in kW
    capacities = {1 => 3, 2 => 3.5, 3 => 4}

    # Grab all possible target objects and shuffle them
    targets = case load_type
    when :residential
      # this isn't really right as there are "houses" simulating commercial load
      # need some other way to distinguish
      find_by_class 'house'
    else
      raise "Invalid load type"
    end
    targets.shuffle!(random: rng)

    # Place solar until we hit the desired penetration, and build players for
    # all the profiles we use.  Note that we may overshoot the desired
    # penetration by a fraction of an installation -- we don't try to match it
    # exactly
    placed = 0
    players = {}
    until placed >= peak_load * penetration do
      target = targets.shift
      raise "Ran out of targets to add solar to" if target.nil?
      # TODO: the profile chosen needs to be geographically determined, not randomized
      profile = capacities.keys[rng.rand(capacities.size)]
      target.add_nested({
        :class => "ZIPload",
        :comment0 => "// Solar City PV generation rated at #{'%.1f' % capacities[profile]}kW",
        :groupid => "SC_res_zipload_solar",
        :base_power => "sc_gen_#{profile}.value",
        :heatgain_fraction => '0.0',
        :power_pf => '1.0',
        :current_pf => '1.0',
        :impedance_pf => '1.0',
        :impedance_fraction => '0.0',
        :current_fraction => '0.0',
        :power_fraction => '1.0'
      })
      placed += capacities[profile]
      
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
  end
end

# base class for any object we care about in a .glm file
# GLMObject basically just parses lines from the input file into
# a key/value in its Hash-nature
class GLMObject < Hash
  TAB = " " * 2
  
  attr_reader :nested
  
  def self.from_file(dec_line, infile, wrangler, nesting_parent = nil)
    obj = new wrangler, {}, nesting_parent
    obj.populate_from_file dec_line, infile
  end
  
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
    props.each {|key, val| self[key] = val}
  end
  
  # populates this object, declared by dec_line (which is assumed to have just
  # been read from infile) with properties that follow in infile, until
  # the end of the object definition is found.  Also recursively creates
  # more GLMObjects if nested objects are found
  def populate_from_file(dec_line, infile)
    comment_count = blank_count = 0
    done = false
    
    if /^\s*(\w+\s+)?object\s+(\w+)\s+{/.match(dec_line) && !$2.nil?
      self[:class] = $2
      self[:id] = $1.strip unless $1.nil? # this will usually be nil, but some objects are named
    else
      raise "Can't find class of object from '#{dec_line}'" if self[:class].nil?
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
        push_nested self.class.from_file(l, infile, @wrangler, self)
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
    raise "Can't convert a GLMObject with no :class to a string" if self[:class].nil?
    id_s = self[:id] ? self[:id] + ' ' : ''
    out = tab(indent) + id_s + 'object ' + self[:class] + " {\n"
    each do |key, val|
      prop_s = key.to_s
      out += case prop_s
      when /^blank/, /^comment/  
        tab(indent + 1) + val + "\n"
      when /^object/
        val.to_s(indent + 1)
      when 'class', 'id'
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
infilename = ARGV.shift
outfilename = ARGV.shift

wrangler = GLMWrangler.new infilename, outfilename, ARGV
wrangler.parse
wrangler.run
wrangler.sign
wrangler.write