#!/usr/bin/env ruby

# This software is (c) 2012 Michael A. Cohen
# It is released under the simplified BSD license, which can be found at:
# http://www.opensource.org/licenses/BSD-2-Clause
#
# TODO: This is out of date
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

begin
  require 'pry'
rescue LoadError
  warn "Warning: pry gem not found; you can use glm_wrangler without pry, but will get an error if you try to use 'interactive' mode"
end
require 'csv'

version_pieces = RUBY_VERSION.split '.'
unless version_pieces[0] == '1' && version_pieces[1] == '9'
  raise "This script was written for use with ruby 1.9 and will not run correctly on older versions; sorry."
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
  EXT = '.glm'

  def self.glms_in_path(path)
    Dir.glob(File.join(path, '*' + EXT))
  end
  private_class_method :glms_in_path

  # Kick things off based on command line parameters
  # If the first argument in the array is recognized as a GLMWrangler class method,
  # it will be called with the remaining arguments as parameters
  # Otherwise we default to calling ::process on all the arguments
  def self.start_from_cli(args = ARGV)
    method_sym = args.first.to_sym
    respond_to?(method_sym) ? send(method_sym, *args[1..-1]) : process(*args)
  end

  # Do "the works" (parse, edit according to the given commands, sign and output)
  # on a single .glm file
  def self.process(infilename, outfilename = nil, *commands)
    puts "Processing file: #{File.basename(infilename)}"
    wrangler = new infilename: infilename, outfilename: outfilename, commands: commands
    wrangler.run
    wrangler.sign
    wrangler.write
    puts
  end

  # Batch process all the .glm files in a given directory according to the given
  # commands.  Output files go to the specified output path, with the optional
  # file_sub inserted into the file name (if it doesn't contain a '/')
  # or treated as a regex replacement (if it does contain a '/')
  def self.batch(inpath, outpath, file_sub = '', *commands)
    infiles = glms_in_path inpath
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
      process infile, outfile, *commands
    end
  end

  def initialize(options)
    @infilename = options[:infilename]
    @outfilename = options[:outfilename]
    @commands = options[:commands]
    @lines = []
    parse! if @infilename
    @lines += options[:lines] || []
  end
  
  # Parse the .glm input file into ruby objects
  def parse!
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
  def sign(commands = @commands)
    commands = commands.join(' ') if commands.respond_to? :join
    first_content_i = @lines.index {|l| !l.blank? && !l.comment?}
    raise "Couldn't find any non-blank, non-comment lines in the .glm" if first_content_i.nil?
    signature1 = "// Wrangled by #{self.class} (using GLMWrangler #{VERSION}) from #{@infilename} to #{@outfilename}"
    signature2 = "// by #{ENV['USERNAME'] || ENV['USER']} at #{Time.now.getlocal}"
    command_str = '// Wrangler commands: ' + (commands.blank? ? '[no commands - defaulted to interactive session]' : commands)
    @lines.insert first_content_i, signature1, signature2, command_str, ''
  end
  
  # Write out the .glm file based on @lines
  def write
    if @outfilename
      puts "Writing #{@outfilename}"
      File.open(@outfilename, 'w') {|f| @lines.each {|l| f.puts l} }
    else
      puts "No destination file given, exiting without writing."
    end
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
  
  def interactive
    pry
  end

end

# base class for any object we care about in a .glm file
# GLMObject basically just parses lines from the input file into
# a key/value in its Hash-nature
class GLMWrangler::GLMObject < Hash
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

    # If there's a module named after this object's GLM class,
    # extend the object with the module
    mod = get_module(@class.split('_').map {|s| s.capitalize}.join(''))
    extend(mod) if mod
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
    
    if /^\s*(\w+\s+)?object\s+(\w+)(:(\d*))?\s+{/.match(dec_line) && !$2.nil?
      @class = $2
      self[:id] = $1.strip unless $1.nil? # this will usually be nil, but some objects are named
      self[:num] = $4 unless $4.nil?
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
    out = tab(indent) + id_s + 'object ' + @class + (self[:num] ? ":#{self[:num]}" : '') + " {\n"
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

  def get_module(name)
    mod = self.class.const_defined?(name) && self.class.const_get(name)
    mod.instance_of?(::Module) ? mod : nil
  end
  
end

# If this file was started directly from the command line, kick things off now.
# Otherwise we're being required and we'll wait for the requiring file to get
# things started in its own way.
GLMWrangler.start_from_cli if __FILE__ == $0
