#!/usr/bin/env ruby

# This software is (c) 2012 Michael A. Cohen
# It is released under the simplified BSD license, which can be found at:
# http://www.opensource.org/licenses/BSD-2-Clause
# 
# This script basically gives you an object representation of a .glm to work with.
# It can then output the object representation as a new .glm
# Usage:


# Quirks to be aware of:
# - If an object has a property set more than once (e.g. it has more than one
#   name) only the last setting is preserved
# - If there is something after the ';' (e.g. a comment) in an attribute-setting
#   line, the stuff after the ';' will be discarded
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
        obj = GLMObject.new(l, infile, self)
        @lines << obj
        index_obj obj
      else
        # For now anything that isn't inside an object declaration just gets
        # saved as a literal string.  We could get fancy and create classe for
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
  
  # put a line after all other comments at the top of the .glm that notes that
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

end

# base class for any object we care about in a .glm file
# GLMObject basically just parses lines from the input file into
# a key/value in its Hash-nature
class GLMObject < Hash
  TAB = " " * 2
  
  attr_reader :nested
  
  def initialize(dec_line, infile, wrangler, nesting_parent = nil)
    obj_count = comment_count = blank_count = 0
    done = false
    # Is there a semicolon after the closing '}' for this object?
    # Defaults to true because having a semicolon is always safe
    # but we try to remember if the original file doesn't use one
    # and do the same.  Note that this could cause problems if you
    # move the object from a place in the tree where it doesn't
    # need a semicolon (i.e. at the top layer) to a place where it does
    # (i.e. inside another object)
    @semicolon = true
    @nested = []
    @wrangler = wrangler
    @nesting_parent = nesting_parent
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
        obj = GLMObject.new(l, infile, wrangler, self)
        self[('object' + obj_count.to_s).to_sym] = obj
        @nested << obj
        obj_count += 1
      when /^([\w.]+)\s+([^;]+);(.*)$/
        # note: there will be trouble here if a property is set to a quoted
        # string that contains a ';'
        self[$1.to_sym] = $2
        puts "Ignoring extra stuff after semicolon in: '#{l}'" unless $3.empty?
      else
        raise "Object property parser hit a line it doesn't understand: '#{l}'"
      end
    end
  end
  
  def comment?; false end
  
  def tab(level)
    TAB * level
  end
  
  def to_s(indent = 0)
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
        tab(indent + 1) + prop_s + ' ' + val + "; \n"
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