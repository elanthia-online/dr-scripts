#!/usr/bin/env ruby
# frozen_string_literal: true

# Regenerates the guess_table block in data/base-aesthene.yaml.
#
# Run it from the repository root after changing lock_answers, dictionary or
# opening, or the solver's scoring:
#
#   ruby util/aesthene_guess_table.rb
#
# It solves every known answer with aesthene.lic's own solver (tens of
# seconds) and writes each guess that had to be scored, with the digest of the
# lists it was built for. spec/aesthene_spec.rb fails while the stored digest
# does not match the data file.

require 'yaml'

root = File.expand_path('..', __dir__)
lic = File.join(root, 'aesthene.lic')
data_path = File.join(root, 'data', 'base-aesthene.yaml')

# The script ends by starting itself; load only its definitions.
source = File.read(lic).sub(/^Aesthene\.new\s*\z/, '')
eval(source, TOPLEVEL_BINDING, lic)

data = YAML.safe_load_file(data_path)
answers, = AestheneWords.answers(data['lock_answers'], nil)
dictionary = AestheneWords.dictionary(data['dictionary'], answers)
opening, = AestheneWords.normalize(data['opening'])
opening = opening.first

table = AestheneSolver.build_table(answers, dictionary, opening)
block = +"guess_table:\n"
block << "  digest: #{AestheneSolver.digest(answers, dictionary, opening)}\n"
block << "  guesses:\n"
table.each { |key, guess| block << "    '#{key}': #{guess}\n" }

text = File.read(data_path)
text = if text.match?(/^guess_table:\n/)
         text.sub(/^guess_table:\n(?:[ ].*\n)*/, block)
       else
         text.sub(/^(opening: .*\n)/) { "#{Regexp.last_match(1)}#{block}" }
       end
File.write(data_path, text)

puts "wrote #{table.size} guesses for #{answers.size} answers to #{data_path}"
