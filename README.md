# GLMWrangler

GLMWrangler is a tool for understanding and editing electrical distribution feeder model files (".glm files") used with [GridLAB-D](http://gridlabd.org). You can use GLMWrangler as an alternative or compliment to the `Feeder_Generator.m` Matlab script ([svn](http://gridlab-d.svn.sourceforge.net/viewvc/gridlab-d/Taxonomy_Feeders/PopulationScript/)) provided by Pacific Northwest National Lab (PNNL). GLMWrangler will read .glm files generated by `Feeder_Generator.m` as well as the basic "[taxonomy feeders](http://sourceforge.net/apps/mediawiki/gridlab-d/index.php?title=Feeder_Taxonomy)".

This document briefly reviews the usage and capabilities of GLMWrangler. Most likely you will need to write some custom ruby code to make it do what you need, but I have tried to make this as straightforward as possible. Feedback and patches are welcome; feel free to get in touch with me at **mcohen |the-usual-symbol| rollingturtle.com**.

## License

GLMWrangler is &copy; 2012 by Michael A. Cohen. It is released under the [simplified BSD license](http://www.opensource.org/licenses/BSD-2-Clause).

## Requirements

GLMWrangler was written for ruby 1.9 and will not run under ruby 1.8. It should work fine under 2.0 though I have not tested this yet. I encourage you to install the [pry gem](https://rubygems.org/gems/pry) to make learning and using GLMWrangler easier, but it is not strictly required.

## Basic Usage

The GLMWrangler script is built around the `GLMWrangler` class. An instance of `GLMWrangler` generally represents a .glm file that is loaded from disk, manipulated in some way, and then written out to another file (specifically, this sequence of events is performed by the `GLMWrangler::process` method). There are also other ways to use it, however; for instance, you can fabricate a new .glm file from scratch, without using an input file. 

Assuming you have the pry gem installed, the easiest way to get a feeling for GLMWrangler is to run it from the command line with an existing .glm file as the single argument, like:

    ruby glm_wrangler.rb path/to/the.glm

This will open an "interactive" session, which is really just a pry session in the scope of a `GLMWrangler` instance initialized with the input file you specified.

### Basic Functionality of a GLMWrangler

Once you're at the pry prompt, you can access all of the `GLMWrangler`'s instance methods and variables; poke around! The core of the `GLMWrangler` is its `@lines` array, which essentially contains all of the lines that were in your input file (as strings) *except* that object declaration blocks are rolled into a single instance of `GLMWrangler::GLMObject` each. For example, consider creating a `GLMWrangler` from this snippet of a file:

	// $Id: R1-12.47-1.glm
	// 12.5 kV feeder
	//*********************************************
	clock{
	     timestamp '2000-01-01 0:00:00';
	     stoptime '2000-01-01 1:00:00';
	     timezone EST+8EDT;
	}

	object regulator:4383 {
	     name R1-12-47-1_reg_1;
	     from R1-12-47-1_node_617;
	     to R1-12-47-1_meter_21;
	     phases ABCN;
	     configuration feeder_reg_cfg;
	}

The `@lines` array of the `GLMWrangler` will have ten elements. The first nine elements will be strings containing the header comments, clock declaration and properties, and the blank line (an empty string).  Note that the parser does not currently consider `clock` to be an "object" because the declaration doesn't begin with "`object`". The tenth element of `@lines` will be a `GLMObject` based on `regulator:4383`. `GLMObject` inherits from the standard ruby `Hash` and allows you to read or edit the properties of the object using the standard `[]` and `[]=` methods, using the symbol representation of the property names. (If you're not familiar with ruby symbols, just add a `:` before the property name.) Property values parsed from files are always treated as strings (with the trailing semicolon dropped) but if you set a property to another type (e.g. something numeric) GLMWrangler will generally handle this properly.

### Sample Interactive Usage

Let's return to the pry prompt to see an example that also introduces the very handy `GLMWrangler#find_by_X` virtual methods, which work similarly to Ruby on Rails' ActiveRecord `find_by_X` virtual methods. (I refer to these methods as "virtual" since they are actually implemented with the ruby "method_missing" hook.  But you can think of them as regular methods for day-to-day use.) At the pry prompt, still using the above file snippet, you could type:

    regs = find_by_class('regulator')

The `find_by_X` method scans the `@lines` array for `GLMObject`s having the property value specified and returns an array of matching objects.  "class" is a special property that does what you'd expect; it gives you the GridLAB-D class of the object. Thus, `regs` now references an array containing a single `GLMObject` -- the regulator. You could get at the `GLMObject` itself by accessing `regs.first` (or equivalently `regs[0]`) but since you know there's only one regulator you can take a shortcut by using the second parameter of the `find_by_X` method to enforce the number of results you're expecting:

    reg = find_by_class('regulator', 1)

When the second parameter is specified, the method will raise an error if a different number of results is found; useful for making sure you're not making changes to more (or fewer) objects than you intended. If the second parameter is "1", specifically, the method will return the single `GLMObject` directly rather than wrapping it in an array.

Now that you have a handle on the regulator, you can easily find the value of a property:

    cfg_name = reg[:configuration]

Or set the value of a property:

    reg[:configuration] = 'some_other_config_name'

If you set a property that the object didn't have in the original file, it will be appended to the end of the object declaration if/when the output file is written.

You can `find_by_` any property, not just `class`, and you can chain these methods however you like. For instance, if you want to change the regulator's configuration's `time_delay` property to 60 in one line, you can type:

    find_by_name(find_by_class('regulator', 1)[:configuration], 1)[:time_delay] = 60

.glm files have multiple ways of relating objects in the radial hierarchy of the feeder. For instance, an object declaration might be nested inside its parent object's declaration, or it might be declared at the "top level" of the file and specify a `parent` property, or it might have `from` and `to` properties. Often we just want to walk up or down the hierarchy without caring exacly how the parent/child relationship is specified. For this, GLMWrangler provides the `GLMObject#upstream` and `GLMObject#downstream` methods. `#upstream` will by default return a single parent object and raise an error if zero or multiple upstream nodes are identified, although the error-raising behavior is parameterized. `#downstream` will return an array of the `GLMObject`'s downstream objects.

### Exiting an Interactive Session

When you're all done with the interactive pry session, just type `exit`. Because we did not specify an output file, when you exit this example session you will see a brief message saying that no file was written.

## Command Line Usage

In the example in the previous section, we could interactively explore and manipulate the .glm file, but our changes were lost when we exited the session. To get real work done, let's examine how glm_wrangler.rb interprets its command line arguments. The most general way to call the script is:

    ruby glm_wrangler.rb some_class_method arg_1 arg_2 arg_n

This effectively calls:

    GLMWrangler::some_class_method('arg_1', 'arg_2', 'arg_n')

### Default Behavior and the `process` Method

As a convenience, if the first argument to glm_wrangler.rb is not recognized as a class method of `GLMWrangler`, the script defaults to passing all the arguments to `GLMWrangler::process`.  The `process` method takes an input file, an output file, and an arbitrarily long list of commands. These commands are instance methods of `GLMWrangler` that are run (in order) on the input before writing the result to the output. The `process` method also "signs" its work by inserting a comment into the .glm file stating what commands were run, when and by whom (see `GLMWrangler#sign` for details). Commands that contain characters that might be interpreted by the shell should be quoted. For example:

    ruby glm_wrangler.rb process path/to/infile.glm path/to/outfile.glm command1 "command2('with', 'params')" command3

Equivalently we can omit "process" since it is the default class method:

    ruby glm_wrangler.rb path/to/infile.glm path/to/outfile.glm command1 "command2('with', 'params')" command3

If `process` is not passed any commands, it defaults to the `interactive` command, which just opens a pry session as we saw in the previous section. The output file is also optional, as sometimes we just want to explore but not save our changes. These optional arguments to `process` are why the simple example usage from the first section was able to open an interactive session with no output destination:

    ruby glm_wrangler.rb path/to/the.glm

If we want to save the results, we simply provide an output file:

    ruby glm_wrangler.rb path/to/the.glm path/to/output.glm

### The `batch` Method

Another useful `GLMWrangler` class method is `batch`. `batch` finds all the .glm files in an input folder, `process`es each one individually using a list of commands, then outputs them to a destination folder. It can optionally do some simple substitution on filenames as well. For example:

    ruby glm_wrangler.rb batch source_folder/ destination_folder/ t0/foo command1 command2

This invocation will find all .glm files in `source_folder/`, apply `GLMWrangler#command1` and `GLMWrangler#command2` to them, then output the results to `destination_folder/`. If "t0" appears in an individual input filename, "foo" will be substituted for "t0" in the output filename. See `GLMWrangler::batch` for more details.

## Customizing GLMWrangler

Most likely you will want to write some custom methods for GLMWrangler to perform your manipulations in a reproducible way. I recommend doing this by creating a class that inherits from `GLMWrangler` in a separate file, to keep your personal methods separate from the GLMWrangler core. The file `my_glm_wrangler.rb` shows an example of this. Unfortunately many of my custom methods won't run for you because I can't share the data files they depend upon, but the code should give you a sense of the range of possibilities. A basic custom GLMWrangler (stored in the same directory as the core `glm_wrangler.rb`) would look like this:

    require_relative 'glm_wrangler'

    class MyGLMWrangler < GLMWrangler

      def self.my_class_method
        # class method content
      end

      def my_instance_method
        # instance method content
      end
    end

    MyGLMWrangler.start_from_cli

The last line just makes your `MyGLMWrangler` usable from the command line in the same way as the standard `GLMWrangler`.

### Class-Aware `GLMObject`s

If you'd like to give `GLMObject` additional capabilities you can, of course, reopen it and add methods to your heart's content. But often you'd like to add methods that only make sense for a certain class of objects (here I mean a GridLAB-D class, like "node" or "overhead_line"). GLMWrangler has an easy hook for this; just define a submodule of `GLMWrangler::GLMObject` that's named after a .glm class (CamelCased). For example, let's say you want to be able to access the `transformer_configuration` of any `transformer` in one step, by calling a `#configuration` method. You simply declare this module:

	module GLMWrangler::GLMObject::Transformer
	  def configuration
	    @wrangler.find_by_name self[:configuration], 1
	  end
	end

Now any `GLMObject` with a class property of "transformer" will respond to a `configuration` method that returns the `GLMObject` for its configuration.

Note the use of the `GLMObject`'s `@wrangler` instance variable here. This variable holds a references to the `GLMWrangler` instance to which the `GLMObject` belongs, so that each `GLMObject` can find other objects in the file that it is related to.

There are several other class-specific modules in `my_glm_wrangler.rb`; see, for example, `GLMWrangler::GLMObject::House`.

## Gotchas and Caveats

GLMWrangler is still quite immature. Here are a few rough edges to be aware of.

* The `find_by_X` methods only search the "top level" `@lines` array; they will miss objects that were declared nested inside other objects. To get at nested objects, use the `GLMObject#nested` attribute reader.
* I have so far paid very little attention to performance. In particular, the commonly-used `find_by_X` methods are totally naive; they scan through the entire `@lines` array each time, with no caching or indexing. So far performance has been  adequate for my needs (doing fairly complex operations on the taxonomy feeders) but YMMV if you are working with very large model files.
* If an object has a property set more than once in a .glm file (e.g. it has more than one name) only the last setting is preserved by the GLMWrangler parser.
* If there is something after the ';' (e.g. a comment) in an object attribute declaration line, the stuff after the ';' will be preserved by GLMWrangler and written back to the output file, but will not be easily editable.
* GLMWrangler does not make an attempt to preserve the nature of the whitespace in the input .glm file, although it does indent sanely. Thus, to compare the manipulated version to your original on the command line you should use `diff -b` which ignores whitespace changes.
* The parser is not guaranteed to correctly interpret all legal .glm files; there are some edge cases that will definitely break it. For instance, a semicolon in the middle of a quoted property value will be interpreted as the end of the property declaration; the parser is not smart enough to know that it should ignore this marker inside quoted strings.

## See Also

You may find my [taxonomy feeder visualizations](http://emac.berkeley.edu/gridlabd/taxonomy_graphs/) helpful for understanding the topology of the taxonomy feeders.