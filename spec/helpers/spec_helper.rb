require 'rspec'
require 'rack/test'
include RSpec::Matchers

# delete previous log directory !!
FileUtils.rm_rf "#{__dir__}/../../log" if File.directory? "#{__dir__}/../../log"

require_relative '../../lib/moviemasher.rb'
MovieMasher.configure "#{__dir__}/config.yml"

def spec_file dir, name
	JSON.parse(File.read("#{__dir__}/media/json/#{dir}/#{name}.json"))
end
def spec_job(input_id, output_id = 'video_h264', destination = 'file_log')
	job = spec_job_from_files input_id, output_id, destination
	output = job['outputs'][0]
	input = job['inputs'][0]
	input['base_source'] = spec_file('sources', 'file_spec')
	input['base_source']['directory'] = File.dirname __dir__
	destination = job['destination']
	#puts job.inspect
	input['source']['directory'] = __dir__
	destination['directory'] = File.dirname(File.dirname __dir__)
	job
end
def spec_job_from_files(input_id = nil, output_id = nil, destination_id = nil)
	job = Hash.new
	job['id'] = input_id
	job['inputs'] = Array.new
	job['outputs'] = Array.new
	job['destination'] = spec_file('destinations', destination_id) if destination_id
	job['inputs'] << spec_file('inputs', input_id) if input_id
	job['outputs'] << spec_file('outputs', output_id) if output_id
	mod_media = nil
	job['inputs'].each do |input|
		if MovieMasher::Type::Mash == input['type']
			# modular media needs to be loaded
			mash = input['source'] 
			if MovieMasher::Mash.hash? mash
				referenced = Hash.new
				mash['tracks'].each do |track_type, tracks|
					tracks.each do |track|
						MovieMasher::Mash.media_count_for_clips(mash, track['clips'], referenced)  
					end
				end
				expect(referenced.empty?).to be_false
				referenced.each do |media_id, reference|
					unless reference[:media]
						mod_media = spec_modular_media unless mod_media
						if mod_media[media_id]
							mash['media'] << mod_media[media_id]
						else
							raise "could not find or create media for #{media_id}"
						end
					end
				end
			end
		end
	end
	job
end
ModularMedia = Hash.new
def spec_modular_media
	if ModularMedia.empty?
		js_dir = "#{__dir__}/../../../angular-moviemasher/app/module"
		js_dirs = Dir["#{js_dir}/*/*.json"]
		js_dirs += Dir["#{js_dir}/*/*/*.json"]
		js_dirs.each do |json_file|
			json_text = File.read json_file
			json_text = "[#{json_text}]" unless json_text.start_with? '['
			medias = JSON.parse(json_text)
			medias.each do |media|
				ModularMedia[media['id']] = media
			end
		end
	end
	ModularMedia
end
def spec_job_output_path job, processed_job
	destination = processed_job[:destination]	
	dest_path = destination[:file]
	if dest_path and File.directory?(dest_path) then
		dest_path = Dir["#{dest_path}/*"].first
		#puts "DIR: #{dest_path}"
	end
	dest_path
end
def spec_process_job_files(input_id, output = 'video_h264', destination = 'file_log')
	job = spec_job input_id, output, destination
	output = job['outputs'][0]
	input = job['inputs'][0]	
	processed_job = MovieMasher.process job
	if processed_job[:error]
		puts processed_job[:error] 
		puts processed_job[:commands]
	end
	expect(processed_job[:error]).to be_nil
	#puts processed_job.inspect
	destination_file = spec_job_output_path job, processed_job
	expect(destination_file).to_not be_nil
	#puts "destination_file exists #{File.exists? destination_file} #{destination_file}"
	expect(File.exists?(destination_file)).to be_true
	case output['type']
	when MovieMasher::Type::Audio, MovieMasher::Type::Video
		spec_expect_duration destination_file, processed_job[:duration]
	end
	spec_expect_dimensions(destination_file, output['dimensions']) if MovieMasher::Type::Mash == input['type']
	spec_expect_fps(destination_file, output['fps']) if MovieMasher::Type::Video == output['type'] 
	
	[job, processed_job]
end
def spec_expect_duration destination_file, duration
	expect(cache_get_info(destination_file, 'duration').to_f).to be_within(0.1).of duration
end
def spec_expect_fps destination_file, fps
	expect(cache_get_info(destination_file, 'fps').to_i).to eq fps.to_i
end
def spec_expect_dimensions destination_file, dimensions
	expect(cache_get_info(destination_file, 'dimensions')).to eq dimensions
end

RSpec.configure do |config|
	config.expect_with :rspec do |c|
		c.syntax = :expect
	end
	config.include Rack::Test::Methods
	config.after(:suite) do
		
  	end
end