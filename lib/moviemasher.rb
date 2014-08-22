require_relative 'utils/float_utils'
module MovieMasher
	QueueReceiveMessagesWaitTime = 2
	TypeVideo = 'video'
	TypeSequence = 'sequence'
	TypeAudio = 'audio'
	TypeImage = 'image'
	TypeFont = 'font'
	TypeFrame = 'frame'
	TypeMash = 'mash'
	TypeWaveform = 'waveform'
	TypeTheme = 'theme'
	TypeEffect = 'effect'
	TypeMerger = 'merger'
	TypeScaler = 'scaler'
	TypeTransition = 'transition'
	TrackTypeVideo = TypeVideo
	TrackTypeAudio = TypeAudio
	SourceTypeFile = 'file'
	SourceTypeHttp = 'http'
	SourceTypeHttps = 'https'
	SourceTypeS3 = 's3'
	SourceModeSymlink = 'symlink'
	SourceModeMove = 'move'
	SourceModeCopy = 'copy'
	RegexFunctionCalls = /([\w]+)\((.+)\)/
	RegexVariables = /([\w]+)/
	AVVideo = 'v'
	AVAudio = 'a'
	AVBoth = 'b'
	TrackTypes = [TrackTypeAudio, TrackTypeVideo]
	MASH_FILL_NONE = 'none'
	MASH_FILL_STRETCH = 'stretch'
	MASH_FILL_CROP = 'crop'
	MASH_FILL_SCALE = 'scale'	
	MASH_VOLUME_NONE = FLOAT_ONE
	MASH_VOLUME_MUTE = FLOAT_ZERO
	INTERMEDIATE_AUDIO_EXTENSION = 'wav' # file extension for audio portion
	INTERMEDIATE_VIDEO_CODEC = 'png' #'mpeg2video';#''; # -vcodec switch
	INTERMEDIATE_VIDEO_EXTENSION = 'mov' #'mpg'; # file extension for video portion
	PIPE_VIDEO_EXTENSION = 'mpg' # used for piped and concat files
	PIPE_VIDEO_FORMAT = 'yuv4mpegpipe' # -f:v switch for piped and concat files
	
	@@queue = nil
	@@formats = nil
	@@codecs = nil
	@@job = nil
	def self.app_exec(cmd, out_file = '', duration = nil, precision = 1, app = 'ffmpeg')
		#puts "app_exec #{app}"
		outputs_file = (('/dev/null' != out_file) and (not out_file.empty?))
		whole_cmd = CONFIG["path_#{app}"]
		whole_cmd += ' ' + cmd
		FileUtils.mkdir_p(File.dirname(out_file)) if outputs_file
		whole_cmd += " #{out_file}" unless out_file.empty?
		#puts whole_cmd
		@@job[:commands] << whole_cmd if @@job
		result = __shell_command whole_cmd
		if outputs_file and not out_file.include?('%') then	
			raise "Failed to generate file #{result}\n#{cmd.gsub(';', ";\n")}" unless File.exists?(out_file)
			raise "Generated zero length file #{result}" unless File.size?(out_file)
			if duration then
				audio_duration = __cache_get_info(out_file, 'audio_duration')
				video_duration = __cache_get_info(out_file, 'video_duration')
				#puts "audio_duration: #{audio_duration} video_duration: #{video_duration}"
				raise "could not determine duration of #{out_file} #{result}" unless audio_duration or video_duration
				raise "generated file with incorrect duration #{duration} != #{audio_duration} or #{video_duration}" unless float_cmp(duration, video_duration.to_f, precision) or float_cmp(duration, audio_duration.to_f, precision)
			end
		end 
		result
	end
	def self.codecs
		@@codecs = app_exec('-codecs') unless @@codecs
		@@codecs
	end
	def self.formats
		@@formats = app_exec('-formats') unless @@formats
		@@formats
	end
	def self.mash_search(mash, id, key = :media)
		mash[key].each do |item|
			return item if id == item[:id]
		end
		nil
	end
	def self.output_path output
		out_file = CONFIG['dir_temporary']
		out_file += '/' unless out_file.end_with? '/'
		out_file += output[:job_identifier] + '/' if output[:job_identifier]
		out_file += output[:identifier] + '/' if output[:identifier]	
	end
	def self.process orig_job
		begin
			@@job = valid? orig_job # makes a copy with keys as symbols instead of strings
			raise "invalid job" unless @@job  
			#puts "job #{@@job.inspect}"
			input_ranges = Array.new
			copy_files = Hash.new # key is value of input[:copy] (basename for copied input)
			output_inputs = Hash.new # key is output id, value is array of intersecting input refs
			video_outputs = Array.new
			audio_outputs = Array.new
			mash_inputs = @@job[:inputs].select { |i| TypeMash == i[:type] }
			@@job[:outputs].each do |output|
				video_outputs << output unless AVAudio == output[:desires]
				audio_outputs << output unless AVVideo == output[:desires]
			end
			output_desires = (0 < video_outputs.length ? (0 < audio_outputs.length ? AVBoth : AVVideo) : AVAudio)
			__trigger :initiate
			@@job[:inputs].each do |input|
				input_url = __input_url input, (input[:base_source] || @@job[:base_source])
				if input_url then
					if (TypeMash == input[:type]) or __has_desired?(__input_has(input), output_desires) then
						if not @@job[:cached][input_url] then 
							@@job[:cached][input_url] = __cache_input input, (input[:base_source] || @@job[:base_source]), input_url
						end
						# TODO: handle copy flag in input
						copy_files[input[:copy]] = @@job[:cached][input_url] if input[:copy]
					else
						#puts "__has_desired?(__input_has(input), output_desires) = #{__has_desired?(__input_has(input), output_desires)}"
						#puts "__has_desired?(#{__input_has(input)}, #{output_desires})"
						#puts "__input_has(input) == output_desires #{__input_has(input) == output_desires}"
					end
					if (TypeMash == input[:type]) then
						input[:source] = JSON.parse(File.read(@@job[:cached][input_url])) 
						__init_input_mash input
					end
				end
				if (TypeMash == input[:type]) and __has_desired?(__input_has(input), output_desires) then
					__cache_job_mash input
				end
			end
			# everything that needs to be cached is now cached
			__set_timing
			if not video_outputs.empty? then
				# make sure visual outputs have dimensions, using input's for default
				input_dimensions = __input_dimensions
				video_outputs.each do |output|
					output[:dimensions] = input_dimensions unless output[:dimensions]
				end
				# sort visual outputs by dimensions, fps
				video_outputs.sort! do |a, b|
					if a[:type] == b[:type] then
						a_ratio = __aspect_ratio(a[:dimensions])
						b_ratio = __aspect_ratio(b[:dimensions])
						if a_ratio == b_ratio then
							a_dims = a[:dimensions].split 'x'
							b_dims = b[:dimensions].split 'x'
							if a_dims[0].to_i == b_dims[0].to_i then
								return 0 if a[:fps] == b[:fps] 
								return (a[:fps].to_i > b[:fps].to_i ? -1 : 1)
							end
							return (a_dims[0].to_i > b_dims[0].to_i ? -1 : 1)
						end
						# different types with different aspect ratios are sorted by type
					end
					return ((TypeVideo == a[:type]) ? -1 : 1)
				end
			
			end
			video_graphs = (video_outputs.empty? ? Array.new : __filter_graphs_video(@@job[:inputs]))
			audio_graphs = (audio_outputs.empty? ? Array.new : __filter_graphs_audio(@@job[:inputs]))
		
		
			# do video outputs first
			video_outputs.each do |output|
				@@output = output
				__build_output output, video_graphs, audio_graphs				
			end
			# then audio and other outputs
			audio_outputs.each do |output|
				@@output = output
				__build_output output, video_graphs, audio_graphs
			end
			@@job[:outputs].each do |output|
				@@output = output
				__transfer_job_output output
			end
		rescue Exception => e
			log_error = "process caught: #{e.message} #{e.backtrace.join "\n"}"#.select{|t|t.include? 'moviemasher'}.first
			puts log_error
			LOG.error { log_error }
			@@job[:error] = log_error
			__trigger :error
		ensure
			@@output = nil
		end
		begin
			__trigger :complete
		rescue Exception => e
			log_error = "process complete caught: #{e.message} #{e.backtrace.select{|t|t.include? 'moviemasher'}.first}"
			puts log_error
			LOG.error { log_error }
			@@job[:error] = log_error
		end
		job = @@job
		@@job = nil
		__flush_cache_files CONFIG['dir_cache'], CONFIG['cache_gigs']
		job
	end
	def self.process_queues rake_args
		run_seconds = CONFIG['process_queues_seconds']
		start = Time.now
		oldest_file = nil
		working_file = "#{CONFIG['dir_queue']}/working.json"
		while run_seconds > (Time.now - start)
			if File.exists? working_file
				# we must have crashed on this file, so log and delete it
				LOG.error { "crashed on job:\n#{File.read working_file}"} unless oldest_file
				File.delete working_file
			end
			#puts "looking for job in #{CONFIG['dir_queue']}"
			oldest_file = Dir["#{CONFIG['dir_queue']}/*.json"].sort_by{ |f| File.mtime(f) }.first
			if oldest_file then
				puts "started #{oldest_file}"
				File.rename oldest_file, working_file
				json_str = File.read working_file
				job = nil
				begin
					job = JSON.parse json_str
				rescue JSON::ParserError
					LOG.error{ "Job could not be parsed as json: #{oldest_file} #{json_str}" }
				end
				process job
				puts "finished #{oldest_file}"
				File.delete working_file
				sleep 1
			else # see if there's one in the queue
				__sqs_request(run_seconds, start) if CONFIG['queue_url']
			end
		end
	end
	def self.valid? job
		valid = false
		if job and job.is_a? Hash then
			job = Marshal.load(Marshal.dump(job))
			__change_keys_to_symbols! job
			if job[:inputs] and job[:inputs].is_a?(Array) and not job[:inputs].empty? then
				if job[:outputs] and job[:outputs].is_a?(Array) and not job[:outputs].empty? then
					job[:callbacks] = Array.new unless job[:callbacks]
					job[:cached] = Hash.new
					job[:calledback] = Hash.new
					job[:error] = ''
					job[:warnings] = Array.new
					job[:commands] = Array.new
					job[:id] = UUID.new.generate unless job[:id]
					job[:identifier] = UUID.new.generate
					job[:inputs].each do |input| 
						__init_input input
					end
					found_destination = !! job[:destination]
					__init_destination job[:destination] if found_destination
					job[:outputs].each do |output| 
						__init_output output, job[:identifier]
						destination = output[:destination]
						if destination then
							__init_destination destination
							found_destination = true
						end
					end
					valid = job if found_destination
					puts "found no destination" unless found_destination
				end
			end
		end
		#puts "JOB: #{JSON.pretty_generate valid}"
		valid
	end
	def self.__aspect_ratio dimensions
		result = dimensions
		if dimensions then
			wants_string = dimensions.is_a?(String)
			dimensions = dimensions.split('x') if wants_string
			w = dimensions[0].to_i
			h = dimensions[1].to_i
			gcf = __cache_gcf(w, h)
			result = [w / gcf, h / gcf]
			result = result.join('x') if wants_string
		end
		result
	end
	def self.__audio_from_file path
		raise "__audio_from_file with invalid path" unless path and (not path.empty?) and File.exists? path
		out_file = "#{File.dirname path}/#{File.basename path}-intermediate.#{INTERMEDIATE_AUDIO_EXTENSION}"
		unless File.exists? out_file then
			cmds = Array.new
			cmds << __cache_switch(path, 'i')
			cmds << __cache_switch(2, 'ac')
			cmds << __cache_switch(44100, 'ar')
			app_exec cmds.join(' '), out_file
		end
		out_file
	end
	def self.__build_output output, video_graphs, audio_graphs
		unless output[:rendering] then
			avb = __output_desires output
			cmds = Array.new
			#avb = (audio_graphs.empty? ? AVVideo : (video_graphs.empty? ? AVAudio : AVBoth))
			#puts "avb = #{avb}"
			video_duration = FLOAT_ZERO
			audio_duration = FLOAT_ZERO
			out_path = __render_path output
		
			output[:rendering] = out_path
			out_path_split = out_path.split('/')
			if TypeSequence == output[:type] then
				output[:sequence] = out_path_split.pop 
				output[:rendering] = out_path_split.join '/'
			end
			output[:file] = __render_path_partial output

			unless AVAudio == avb then # we've got video
				if 0 < video_graphs.length then
					if 1 == video_graphs.length then
						graph = video_graphs[0]
						video_duration = graph.duration
						cmd = graph.command output
						raise "Could not build complex filter" if cmd.empty?
					else 
						cmd = __filter_graphs_concat output, video_graphs
						raise "Could not build complex filter" if cmd.empty?
						video_graphs.each do |graph|
							video_duration += graph.duration
						end
					end
					cmds << __cache_switch("'#{cmd}'", 'filter_complex')
				end
			end
			unless AVVideo == avb then # we've got audio
				audio_graphs_count = audio_graphs.length
				if 0 < audio_graphs_count then
					data = audio_graphs[0]
					if 1 == audio_graphs_count and 1 == data[:loop] and (not __gain_changes(data[:gain])) and float_cmp(data[:start_seconds], FLOAT_ZERO) then
						# just one non-looping graph, starting at zero with no gain change
						raise "zero length #{data.inspect}" unless float_gtr(data[:length_seconds], FLOAT_ZERO)
						audio_duration = data[:length_seconds]
						data[:waved_file] = __audio_from_file(data[:cached_file]) unless data[:waved_file]
					else 
						# merge audio and feed resulting file to ffmpeg
						audio_cmd = ''
						counter = 1
						start_counter = FLOAT_ZERO
						audio_graphs_count.times do |audio_graphs_index|
							data = audio_graphs[audio_graphs_index]
							loops = data[:loop] || 1
							volume = data[:gain]
							start = data[:start_seconds]
							raise "negative start time" unless float_gtre(start, FLOAT_ZERO)
							raise "zero length #{data.inspect}" unless float_gtr(data[:length_seconds], FLOAT_ZERO)
							data[:waved_file] = __audio_from_file(data[:cached_file]) unless data[:waved_file]
							audio_cmd += " -a:#{counter} -i "
							counter += 1
							audio_cmd += 'audioloop,' if 1 < loops
							audio_cmd += "playat,#{data[:start_seconds]},"
							audio_cmd += "select,#{data[:trim_seconds]},#{data[:length_seconds]}"
							audio_cmd += ",#{data[:waved_file]}"
							audio_cmd += " -t:{float_string data[:length_seconds]}" if 1 < loops
							if __gain_changes(volume) then
								volume = volume.to_s unless volume.is_a?(String)
								volume = "0,#{volume},1,#{volume}" unless volume.include?(',') 
								volume = volume.split ','
								z = volume.length / 2
								audio_cmd += " -ea:0 -klg:1,0,100,#{z}"
								z.times do |i|
									p = (i + 1) * 2
									pos = volume[p - 2].to_f
									val = volume[p - 1].to_f
									pos = (data[:length_seconds] * loops.to_f * pos) if (float_gtr(pos, FLOAT_ZERO)) 									
									audio_cmd += ",#{float_precision(start + pos)},#{val}"
								end
							end
							#puts "audio_duration #{data[:start_seconds]} + #{data[:length_seconds]}"
							audio_duration = float_max(audio_duration, data[:start_seconds] + data[:length_seconds])
						end
						audio_cmd += ' -a:all -z:mixmode,sum'
						audio_cmd += ' -o'
						audio_path = output_path output
						audio_path += "audio-#{Digest::SHA2.new(256).hexdigest(audio_cmd)}.#{INTERMEDIATE_AUDIO_EXTENSION}"
						unless File.exists? audio_path then
							app_exec(audio_cmd, audio_path, audio_duration, 5, 'ecasound')
						end
						data = Hash.new
						data[:type] = TypeAudio
						data[:trim_seconds] = FLOAT_ZERO
						data[:length_seconds] = audio_duration
						data[:waved_file] = audio_path
					end
					# data is now just one wav file - audio_duration may be less or more than video_duration
					if TypeWaveform == output[:type] then
						dimensions = output[:dimensions].split 'x'
						cmds << __cache_switch(data[:waved_file], '--input')
						cmds << __cache_switch(dimensions.first, '--width')
						cmds << __cache_switch(dimensions.last, '--height')
						cmds << __cache_switch(output[:forecolor], '--linecolor')
						cmds << __cache_switch(output[:backcolor], '--backgroundcolor')
						cmds << __cache_switch('0', '--padding')
						cmds << __cache_switch('', '--output')
						app_exec cmds.join(' '), out_path, nil, nil, 'wav2png'
						cmds = Array.new
					else
						cmds << __cache_switch(data[:waved_file], 'i')
						unless float_cmp(data[:trim_seconds], FLOAT_ZERO) and float_cmp(data[:length_seconds], data[:duration_seconds]) then
							cmds << __cache_switch("'atrim=start=#{data[:trim_seconds]}:duration=#{audio_duration},asetpts=expr=T-STARTT'", 'af') 
						end
				
					end
				end
			end
			unless cmds.empty? then # we've got audio and/or video
				type_is_video_or_audio = ( (TypeVideo == output[:type]) or (TypeAudio == output[:type]) )
				duration = float_max(audio_duration, video_duration)
				cmds << __cache_switch(float_string(duration), 't') if type_is_video_or_audio
				cmd = cmds.join(' ')
				cmd += __output_command output, avb, duration
				
				#puts "__build_output file = #{output[:file]}"
				cmd = '-y ' + cmd
				pass_log_file = "#{File.dirname output[:rendering]}/#{output[:identifier]}"
				duration = nil if TypeImage == output[:type] or TypeSequence == output[:type]
				raise "duration does not match length #{duration} != #{@@job[:duration]}" if duration and not float_cmp(duration, @@job[:duration])
				#puts "DURATIONS\nduration:\n#{duration}\nvideo: #{video_duration}\naudio: #{audio_duration}\noutput: #{output[:duration]}\njob: #{@@job[:duration]}"
				do_single_pass = (not type_is_video_or_audio)
				unless do_single_pass then
					cmd_pass_1 = "#{cmd} -pass 1 -passlogfile #{pass_log_file} -f #{output[:extension]}"
					cmd_pass_2 = "#{cmd} -pass 2 -passlogfile #{pass_log_file}"
					begin
						app_exec cmd_pass_1, '/dev/null'
						app_exec cmd_pass_2, out_path, duration, output[:precision]
					rescue
						@@job[:warnings] << "unable to encode in two passes, retrying in one\n#{cmd}"
						puts @@job[:warnings].last
						do_single_pass = true
					end
				end
				if do_single_pass then
					app_exec cmd, out_path, duration, output[:precision]
				end
			end
		end
	end	
	def self.__cache_gcf a, b 
		 ( ( b == 0 ) ? a : __cache_gcf(b, a % b) )
	end
	def self.__cache_meta_path type, file_path
		parent_dir = File.dirname file_path
		base_name = File.basename file_path
		parent_dir + '/' + base_name + '.' + type + '.txt'
	end
	def self.__cache_set_info(path, key_or_hash, data = nil)
		result = nil
		if key_or_hash and path then
			hash = Hash.new
			if key_or_hash.is_a?(Hash) then
				hash = key_or_hash
			else
				hash[key_or_hash] = data
			end
			hash.each do |k, v|
				info_file_path = __cache_meta_path(k, path)
				File.open(info_file_path, 'w') {|f| f.write(v) }
			end
		end
	end
	def self.__cache_file_type path
		result = nil
		if path then
			result = __cache_get_info path, 'type'
			if not result then
				mime = __cache_get_info path, 'Content-Type'
				if not mime then
					ext = File.extname(path)
					mime = Rack::Mime.mime_type(ext)
					#puts "LOOKING UP MIME: #{ext} #{mime}"
				end
				result = mime.split('/').shift if mime
				__cache_set_info(path, 'type', result) if result 
			end
		end
		result
	end
	def self.__cache_get_info file_path, type
		raise "bad parameters #{file_path}, #{type}" unless type and file_path and (not (type.empty? or file_path.empty?))
		result = nil
		if File.exists?(file_path) then
			info_file = __cache_meta_path type, file_path
			if File.exists? info_file then
				result = File.read info_file
			else
				check = Hash.new
				case type
				when 'type', 'http', 'ffmpeg', 'sox' 
					# do nothing if file doesn't already exist
				when 'dimensions'
					check[:ffmpeg] = true
				when 'video_duration'
					check[:ffmpeg] = true
					type = 'duration'
				when 'audio_duration'
					check[:sox] = true
					type = 'duration'
				when 'duration'
					check[TypeAudio == __cache_file_type(file_path) ? :sox : :ffmpeg] = true
				when 'fps', TypeAudio # only from FFMPEG
					check[:ffmpeg] = true
				end
				if check[:ffmpeg] then
					data = __cache_get_info(file_path, 'ffmpeg')
					if not data then
						cmd = " -i #{file_path}"
						data = app_exec cmd
						__cache_set_info file_path, 'ffmpeg', data
					end
					result = __cache_info_from_ffmpeg(type, data) if data
				elsif check[:sox] then
					data = __cache_get_info(file_path, 'sox')
					if not data then
						cmd = "#{CONFIG['path_sox']} --i #{file_path}"
						#puts "CMD #{cmd}"
						data = __shell_command cmd
						__cache_set_info(file_path, 'sox', data)
					end
					result = __cache_info_from_ffmpeg(type, data) if data
				end
				# try to cache the data for next time
				__cache_set_info(file_path, type, result) if result
			end
		end
		result
	end
	def self.__cache_info_from_ffmpeg type, ffmpeg_output
		result = nil
		case type
		when TypeAudio
			/Audio: ([^,]+),/.match(ffmpeg_output) do |match|
				if 'none' != match[1] then
					result = 1
				end
			end
		when 'dimensions'
			/, ([\d]+)x([\d]+)/.match(ffmpeg_output) do |match|
				result = match[1] + 'x' + match[2]
			end
		when 'duration'
			/Duration\s*:\s*([\d]+):([\d]+):([\d\.]+)/.match(ffmpeg_output) do |match|
				result = 60 * 60 * match[1].to_i + 60 * match[2].to_i + match[3].to_f
			end
		when 'fps'
			match = / ([\d\.]+) fps/.match(ffmpeg_output)
			match = / ([\d\.]+) tb/.match(ffmpeg_output) unless match 
			result = match[1].to_f.round	
		end
		result
	end
	def self.__cache_input input, base_source = nil, input_url = nil
		#puts "__cache_input #{input}, #{base_source}, #{input_url} "
		input_url = __input_url(input, base_source) unless input_url
		cache_url_path = nil
		if input_url then
			cache_url_path = __cache_url_path input_url
			unless File.exists? cache_url_path then
				source = input[:source]
				if source.is_a? String then
					if source == input_url then
						source = __source_from_uri(URI input_url)
					else 
						# base_source must have changed it
						new_source = Marshal.load(Marshal.dump(base_source))
						new_source[:name] = source
						source = new_source
					end
				end
				raise "no source for #{input_url}" unless source
				__cache_source source, cache_url_path
				raise "could not cache #{input_url}" unless File.exists? cache_url_path
			end
			#puts "cached_file #{cache_url_path} #{input}"
			input[:cached_file] = cache_url_path
			case input[:type]
			when TypeVideo
				input[:duration] = __cache_get_info(cache_url_path, 'duration').to_f unless input[:duration] and float_gtr(input[:duration], FLOAT_ZERO)
				input[:no_audio] = ! __cache_get_info(cache_url_path, TypeAudio)
				input[:dimensions] = __cache_get_info(cache_url_path, 'dimensions')
				input[:no_video] = ! input[:dimensions]
			when TypeAudio
				input[:duration] = __cache_get_info(cache_url_path, 'audio_duration').to_f unless input[:duration] and float_gtr(input[:duration], FLOAT_ZERO)
				#TODO: should we be converting to wav to get accurate duration??
				input[:duration] = __cache_get_info(cache_url_path, 'video_duration').to_f unless float_gtr(input[:duration], FLOAT_ZERO)
			when TypeImage 
				input[:dimensions] = __cache_get_info(cache_url_path, 'dimensions')
				#puts "INPUT DIMENSIONS #{input[:dimensions]} for #{input_url}"
				raise "could not determine image dimensions" unless input[:dimensions]
			end
		else
			raise "could not produce an input_url #{input}"
		end
		cache_url_path
	end
	def self.__cache_job_mash input
		mash = input[:source]
		base_source = (input[:base_source] || @@job[:base_source])
		mash[:media].each do |media|
			#puts "__cache_job_mash media #{media[:type]} #{media}"
			case media[:type]
			when TypeVideo, TypeAudio, TypeImage, TypeFont
				__cache_input media, base_source
			end
		end
	end
	def self.__cache_source source, out_file
		FileUtils.mkdir_p(File.dirname(out_file))
		case source[:type]
		when SourceTypeFile
			source_path = __directory_path_name source
			__transfer_file source[:mode], source_path, out_file
		when SourceTypeHttp, SourceTypeHttps
			url = "#{source[:type]}://#{source[:host]}"
			path = __directory_path_name source
			url += '/' unless path.start_with? '/'
			url += path
			uri = URI url
			uri.port = source[:port] if source[:port]
			#params = { :limit => 10, :page => 3 }
			#uri.query = URI.encode_www_form(params)
			Net::HTTP.start(uri.host, uri.port, :use_ssl => (uri.scheme == 'https')) do |http|
				request = Net::HTTP::Get.new uri
				http.request request do |response|
					open out_file, 'w' do |io|
						response.read_body do |chunk|
							io.write chunk
						end
					end
				end
			end
		when SourceTypeS3
			bucket = __s3_bucket source
			bucket_key = __directory_path_name source
    		object = bucket.objects[bucket_key]
			object_read_data = object.read
			File.open(out_file, 'w') { |file| file.write(object_read_data) }
		end
		out_file
	end
	def self.__cache_switch(value, prefix = '', suffix = '')
		switch = ''
		value = value.to_s.strip
		if value #and not value.empty? then
			switch += ' ' # always add a leading space
			if value.start_with? '-' then # it's a switch, just include and ignore rest
				switch += value 
			else # prepend value with prefix and space
				switch += '-' unless prefix.start_with? '-'
				switch += prefix + ' ' + value
				switch += suffix unless switch.end_with? suffix # note lack of space!
			end
		end
		switch
	end
	def self.__cache_url_path url
		path = CONFIG['dir_cache']
		if not path.end_with?('/') then
			path += '/' 
		end
		path += __hash url
		path += '/cached'
		path += File.extname(url)
		path
	end
	def self.__change_keys_to_symbols! hash
		if hash 
			if hash.is_a? Hash then
				hash.keys.each do |k|
					v = hash[k]
					if k.is_a? String then
						k_sym = k.downcase.to_sym
						hash[k_sym] = v
						hash.delete k
					end
					__change_keys_to_symbols! v
				end
			elsif hash.is_a? Array then
				hash.each do |v|
					__change_keys_to_symbols! v
				end
			end
		end
		hash
	end
	def self.__clip_has_audio clip
		has = false
		url = nil
		case clip[:type]
		when TypeAudio
			url = (clip[:source] ? clip[:source] : clip[:audio])
		when TypeVideo
			url = (clip[:source] ? clip[:source] : clip[:audio]) unless 0 == clip[:audio]
		end
		if url
			has = ! clip[:gain]
			has = ! __gain_mutes(clip[:gain]) unless has
		end
		has
	end
	def self.__directory_path_name source
		url = source[:key]
		if not url then
			bits = Array.new
			bit = source[:directory]
			if bit then
				bit = bit[0...-1] if bit.end_with? '/'
				bits << bit
			end
			bit = source[:path]
			if bit then
				bit['/'] = '' if bit.start_with? '/'
				bits << bit
			end
			url = bits.join '/'
			url = __transfer_file_name source, url
		else
			url = __eval_value url
		end
		url
	end
	def self.__eval_hash_recursively data
		data.each do |k,v|
			if v.is_a? String then
				data[k] = __eval_value v
			elsif v.is_a? Hash then
				__eval_hash_recursively data
			end
		end
	end
	def self.__eval_path ob, path_array, is_only_eval
		value = ob
		raise "value false #{path_array}" unless value
		key = path_array.shift
		if key then
			if key.to_i.to_s == key then
				key = key.to_i
			else
				key = key.to_sym 
			end
			raise "#{key} not found in #{value.inspect}" if nil == value[key]
			value = value[key]
			value = __eval_path(value, path_array, is_only_eval) unless path_array.empty?
			raise "value false #{path_array}" if nil == value
		end
		if path_array.empty? then
			if value.is_a?(Hash) or value.is_a?(Array) then
				value = value.inspect unless is_only_eval
			else
				value = value.to_s
			end	
		end
		raise "value false #{path_array}" if nil == value
		value
	end
	def self.__eval_value value
		split_value = eval_split value
		if 1 < split_value.length then
			value = ''
			is_static = true
			#puts "value is split #{split_value.inspect}"
			split_value.each do |bit|
				if is_static then
					value += bit
				else
					split_bit = bit.split '.'
					is_only_eval = (value.empty? and 2 == split_value.length)
					case split_bit.shift
					when 'job'
						evaled = __eval_path(@@job, split_bit, is_only_eval)
					when 'output'
						evaled = __eval_path(@@output, split_bit, is_only_eval)
					else
						evaled = "{#{bit}}"
					end
					if is_only_eval then
						value = evaled
					else
						value += evaled if evaled
					end
				end
				is_static = ! is_static
			end
		end
		value
	end
	def self.__filter_scope_map scope, stack, key
		parameters = stack[key]
		if parameters then
			parameters.map! do |param|
				raise "__filter_scope_map #{key} got empty param #{stack} #{param}" unless param and not param.empty?
				__filter_scope_call scope, param
			end
		end
		((parameters and (not parameters.empty?)) ? parameters : nil)
	end
	def self.__filter_scope_call scope, stack
		raise "__filter_scope_call got false stack #{scope}" unless stack
		result = ''
		if stack.is_a? String then
			result = stack
		else
			array = __filter_scope_map scope, stack, :params
			if array then
				raise "WTF" if array.empty?
				if stack[:function] then
					func_sym = stack[:function].to_sym
					if FilterHelpers.respond_to? func_sym then
						result = FilterHelpers.send func_sym, array, scope
						raise "got false from  #{stack[:function]}(#{array.join ','})" unless result
						
						result = result.to_s unless result.is_a? String
						raise "got empty from #{stack[:function]}(#{array.join ','})" if result.empty?
					else
						result = "#{stack[:function]}(#{array.join ','})"
					end
				else
					result = "(#{array.join ','})"
				end
			end
			array = __filter_scope_map scope, stack, :prepend
			result = array.join('') + result if array
			array = __filter_scope_map scope, stack, :append
			result += array.join('') if array
		end
			raise "__filter_scope_call has no result #{stack}" if result.empty?
		result
	end 
	def self.__filter_parse_scope_value scope, value_str
		#puts "value_str = #{value_str}"
	 	level = 0
		deepest = 0
		esc = '~'
		# expand variables
		value_str = value_str.dup
		value_str.gsub!(RegexVariables) do |match|
			match_str = match.to_s
			match_sym = match_str.to_sym
			if scope[match_sym] then
				scope[match_sym].to_s 
			else
				match_str
			end
		end
		#puts "value_str = #{value_str}"

	 	value_str.gsub!(/[()]/) do |paren|
	 		result = paren.to_s
	 		case result
	 		when '('
	 			level += 1
	 			deepest = [deepest, level].max
	 			result = result + level.to_s + esc
	 		when ')'
	 			result = result + level.to_s + esc
	 			level -= 1
	 		end
	 		result
	 	end
	 	#puts "value_str = #{value_str}"
	 	while 0 < deepest
			value_str.gsub!(Regexp.new("([a-z_]+)[(]#{deepest}[#{esc}]([^)]+)[)]#{deepest}[#{esc}]")) do |m|
				#puts "level #{level} #{m}"
				method = $1
				param_str = $2
				params = param_str.split(',')
				params.each do |param|
					param.strip!
					param.gsub!(Regexp.new("([()])[0-9]+[#{esc}]")) {$1}
				end
				func_sym = method.to_sym
				if FilterHelpers.respond_to? func_sym then
					result = FilterHelpers.send func_sym, params, scope
					raise "got false from  #{method}(#{params.join ','})" unless result
					
					result = result.to_s unless result.is_a? String
					raise "got empty from #{method}(#{params.join ','})" if result.empty?
				else
					result = "#{method}(#{params.join ','})"
				end
				result			
			end
			deepest -= 1
	 		#puts "value_str = #{value_str}"
	 	end
	 	# remove any lingering markers
	 	value_str.gsub!(Regexp.new("([()])[0-9]+[#{esc}]")) { $1 }
	 	# remove whitespace
	 	value_str.gsub!(/\s/, '')
	 	#puts "value_str = #{value_str}"
	 	value_str
	end
	def self.__filter_scope_binding scope
		bind = binding
		scope.each do |k,v|
			bind.eval "#{k.id2name}='#{v}'"
		end
		bind
	end
	def self.__filter_graphs_audio inputs
		graphs = Array.new
		start_counter = FLOAT_ZERO
		
		inputs.each do |input|
			next if input[:no_audio]
			#puts "INPUT: #{input}\n"
			case input[:type]
			when TypeVideo, TypeAudio
				data = Hash.new
				data[:type] = input[:type]
				data[:trim_seconds] = __get_trim input
				data[:length_seconds] = __get_length input
				data[:start_seconds] = input[:start]	
				data[:cached_file] = input[:cached_file]
				data[:duration_seconds] = input[:duration]
				data[:gain] = input[:gain]
				data[:loop] = input[:loop]
				graphs << data
			when TypeMash
				quantize = input[:source][:quantize]
				audio_clips = __mash_clips_having_audio input[:source]
				audio_clips.each do |clip|
					unless clip[:cached_file] then
						media = mash_search input[:source], clip[:id]
						raise "could not find media for clip #{clip[:id]}" unless media
						clip[:cached_file] = media[:cached_file] || raise("could not find cached file")
						clip[:duration] = media[:duration]
					end
					data = Hash.new
					data[:type] = clip[:type]
					data[:trim_seconds] = clip[:trim_seconds]
					data[:length_seconds] = clip[:length_seconds]
					#puts "start_seconds = #{input[:start]} + #{quantize} * #{clip[:frame]}"
					data[:start_seconds] = input[:start].to_f + clip[:frame].to_f / quantize.to_f
					data[:cached_file] = clip[:cached_file]
					data[:gain] = clip[:gain]
					data[:duration_seconds] = clip[:duration]
					data[:loop] = clip[:loop]
					graphs << data
				end
			end
		end
		graphs
	end
	def self.__filter_graphs_concat output, graphs
		cmds = Array.new
		intermediate_output = __output_intermediate
		graphs.length.times do |index|
			graph = graphs[index]
			duration = graph.duration
			cmd = graph.command output
			raise "Could not build complex filter" if cmd.empty?
			cmd += ",format=pix_fmts=yuv420p,fps=fps=#{output[:fps]}"
			cmd = " -filter_complex '#{cmd}' -t #{duration} -vb 200M -r #{output[:fps]} -s #{output[:dimensions]}"
			cmd += __output_command intermediate_output, AVVideo
			out_file = CONFIG['dir_temporary']
			out_file += '/' unless out_file.end_with? '/'
			out_file += output[:identifier] + '/' if output[:identifier]
			out_file += "concat-#{cmds.length}.#{intermediate_output[:extension]}"
			cmd = '-y' + cmd
			app_exec cmd, out_file			
			cmds << "movie=filename=#{out_file}[concat#{cmds.length}]"
		end
		cmd = ''
		cmds.length.times do |i|
			cmd += "[concat#{i}]"
		end
		cmd += "concat=n=#{cmds.length}" #,format=pix_fmts=yuv420p
		cmds << cmd
		cmds.join ';'
	end
	def self.__filter_graphs_video inputs
		graphs = Array.new
		raise "__filter_graphs_video already called" unless 0 == graphs.length
		inputs.each do |input|
			#puts "input #{input}"
			next if input[:no_video]
			case input[:type]
			when TypeMash
				mash = input[:source]
				all_ranges = __mash_video_ranges mash
				all_ranges.each do |range|
					#puts "mash Graph.new #{range.inspect}"
					graph = Graph.new input, range, mash[:backcolor]
					clips = __mash_clips_in_range mash, range, TrackTypeVideo
					if 0 < clips.length then
						transition_layer = nil
						transitioning_clips = Array.new
						clips.each do |clip|
							case clip[:type]
							when TypeVideo, TypeImage
								# media properties were copied to clip BEFORE file was cached, so repeat now
								media = mash_search mash, clip[:id]
								raise "could not find media for clip #{clip[:id]}" unless media
								clip[:cached_file] = media[:cached_file] || raise("could not find cached file")
								clip[:dimensions] = media[:dimensions] || raise("could not find dimensions #{clip} #{media}")
							end	
							if TypeTransition == clip[:type] then
								raise "found two transitions within #{range.inspect}" if transition_layer
								transition_layer = graph.create_layer clip
							elsif 0 == clip[:track] then
								transitioning_clips << clip
							end
						end
						if transition_layer then
							#puts "transitioning_clips[0][:frame] #{transitioning_clips[0][:frame]}" if 0 < transitioning_clips.length
							#puts "transitioning_clips[1][:frame] #{transitioning_clips[1][:frame]}" if 1 < transitioning_clips.length
							raise "too many clips on track zero" if 2 < transitioning_clips.length
							if 0 < transitioning_clips.length then
								transitioning_clips.each do |clip| 
									#puts "graph.new_layer clip"
									transition_layer.layers << graph.new_layer(clip)
								end 
							end
						end
						clips.each do |clip|
							next if transition_layer and 0 == clip[:track] 
							case clip[:type]
							when TypeVideo, TypeImage, TypeTheme
								#puts "graph.create_layer clip"
								graph.create_layer clip
							end
						end
					end
					graphs << graph
				end
			when TypeVideo, TypeImage
				#puts "Graph.new #{input[:range].inspect}"
				graph = Graph.new input, input[:range]
				graph.create_layer(input)
				graphs << graph
			end
		end
		graphs
	end
  	def self.__filter_init id, parameters = Hash.new
  		filter = Hash.new
		filter[:id] = id
		filter[:out_labels] = Array.new
		filter[:in_labels] = Array.new
		filter[:parameters] = parameters
		filter
  	end
	def self.__filter_merger_default
		filter_config = Hash.new
		filter_config[:type] = TypeMerger
		filter_config[:filters] = Array.new
		overlay_config = Hash.new
		overlay_config[:id] = 'overlay'
		overlay_config[:parameters] = Array.new
		overlay_config[:parameters] << {:name => 'x', :value => '0'}
		overlay_config[:parameters] << {:name => 'y', :value => '0'}
		filter_config[:filters] << overlay_config
		filter_config
	end
	def self.__filter_scaler_default
		filter_config = Hash.new
		filter_config[:type] = TypeScaler
		filter_config[:filters] = Array.new
		scale_config = Hash.new
		scale_config[:id] = 'scale'
		scale_config[:parameters] = Array.new
		scale_config[:parameters] << {:name => 'width', :value => 'mm_width'}
		scale_config[:parameters] << {:name => 'height', :value => 'mm_height'}
		filter_config[:filters] << scale_config
		filter_config
	end
	def self.__flush_cache_files(dir, gigs = nil)
		result = false
		gigs = 0 unless gigs
		if File.exists?(dir) then
			kbs = gigs * 1024 * 1024
			ds = __flush_directory_size_kb(dir)
			#puts "__flush_directory_size_kb #{dir} #{ds}"
		
			result = __flush_cache_kb(dir, ds - kbs) if (ds > kbs)
		end
		result
	end
	def self.__flush_cache_kb(dir, kbs_to_flush)
		cmd = "du -d 1 #{dir}"
		result = __shell_command cmd
		#puts "#{cmd} #{result}"
		if result then
			directories = Array.new
			lines = result.split "\n"
			lines.each do |line|
				next unless line and not line.empty?
				bits = line.split "\t"
				next if ((bits.length < 2) || (! bits[1]) || bits[1].empty?)
				next if (bits[1] == dir)
				dir = bits[1]
				dir += '/' unless dir.end_with?('/')
				cached = __cache_get_info(dir, 'cached')
				# try to determine from modification time
				cached = File.mtime(dir) unless cached
				cached = 0 unless cached
				directories << {:cached => cached, :bits => bits}
			end
			unless directories.empty?
				directories.sort! { |a,b| a[:cached] <=> b[:cached] }				
				directories.each do |dir|
					cmd = "rm -R #{dir[:bits][1]}"
					result = __shell_command(cmd)
					#puts "#{cmd} #{result}"
					unless result then
						kbs_to_flush -= dir[:bits][0]
						break if (kbs_to_flush <= 0) 
					end
				end
			end
		end
		(kbs_to_flush <= 0)
	end
	def self.__flush_directory_size_kb(dir)
		size = 0
		cmd = "du -s #{dir}"
		result = __shell_command(cmd)
		if result then
			result = result.split "\t"
			result = result.first
			size += result.to_i if result.to_i.to_s == result
		end
		size
	end
	def self.__gain_changes gain
		does = false;
		#puts "__gain_changes: #{gain}"
		if gain.is_a?(String) and gain.include?(',') then
			gains = gain.split ','
			(gains.length / 2).times do |i|
				does = ! float_cmp(gains[1 + i * 2].to_f, MASH_VOLUME_NONE)
				break if does
			end
		else
			does = ! float_cmp(gain.to_f, MASH_VOLUME_NONE)
		end
		#puts "__gain_changes: #{does} #{gain}"
		does
	end
	def self.__gain_mutes gain
		does = true
		#puts "__gain_mutes: #{gain}"
		if gain.is_a?(String) and gain.include?(',') then
			does = true
			gains = gain.split ','
			gains.length.times do |i|
				does = float_cmp(gains[1 + i * 2].to_f, MASH_VOLUME_MUTE)
				break unless does
			end
		else
			does = float_cmp(gain.to_f, MASH_VOLUME_MUTE)
		end
		#puts "__gain_mutes: #{does} #{gain}"
		does
	end
	def self.__get_length output
		__get_time output, :length
	end
	def self.__get_range input
		range = FrameRange.new(input[:start], 1, 1)
		range(input[:fps]) if TypeVideo == input[:type]
		range
	end	
	def self.__get_time output, key
		length = FLOAT_ZERO
		if float_gtr(output[key], FLOAT_ZERO) then
			sym = "#{key.id2name}_is_relative".to_sym
			if output[sym] then
				if float_gtr(output[:duration], FLOAT_ZERO) then
					if '%' == output[sym] then
						length = (output[key] * output[:duration]) / FLOAT_HUNDRED
					else 
						length = output[:duration] - output[key]
					end
				end
			else 
				length = output[key]
			end
		elsif :length == key and float_gtr(output[:duration], FLOAT_ZERO) then
			output[key] = output[:duration] - __get_trim(output)
			length = output[key]
		end
		length = float_precision length
		length
	end
	def self.__get_trim output
		__get_time output, :trim
	end
	def self.__get_trim_range_simple output
		range = FrameRange.new __get_trim(output), 1, 1
		range.length = __get_length output
		range
	end
	def self.__hash s
		Digest::SHA2.new(256).hexdigest s
	end
	def self.__has_desired? has, desired
		(AVBoth == desired) or (AVBoth == has) or (desired == has) 
	end
	def self.__init_clip input, mash, track_index, track_type
		__init_clip_media input, mash
		input[:frame] = (input[:frame] ? input[:frame].to_f : FLOAT_ZERO)
		# TODO: allow for no start or length in video clips
		# necessitating caching of media if its duration unknown
		raise "mash clips must have length" unless input[:length] and 0 < input[:length]
		input[:range] = FrameRange.new input[:frame], input[:length], mash[:quantize]
		input[:length_seconds] = input[:range].length_seconds unless input[:length_seconds]
		input[:track] = track_index if track_index 
		case input[:type]
		when TypeFrame
			input[:still] = 0 unless input[:still]
			input[:fps] = mash[:quantize] unless input[:fps]
			if 2 > input[:still] + input[:fps] then
				input[:quantized_frame] = 0
			else 
				input[:quantized_frame] = mash[:quantize] * (input[:still].to_f / input[:fps].to_f).round
			end
		when TypeTransition
			input[:to] = Hash.new unless input[:to]
			input[:from] = Hash.new unless input[:from]
			input[:to][:merger] = __filter_merger_default unless input[:to][:merger]
			input[:to][:scaler] = __filter_scaler_default unless input[:to][:scaler] or input[:to][:fill]
			input[:from][:merger] = __filter_merger_default unless input[:from][:merger]
			input[:from][:scaler] = __filter_scaler_default unless input[:from][:scaler] or input[:from][:fill]
		when TypeVideo, TypeAudio
			input[:trim] = 0 unless input[:trim]
			input[:trim_seconds] = input[:trim].to_f / mash[:quantize] unless input[:trim_seconds]
		end
		__init_raw_input input
		# this is done for real inputs during __set_timing
		__init_input_ranges input
		input
  	end
  	def self.__init_destination destination
  		__init_key destination, :identifier, UUID.new.generate	
  		__init_key(destination, :acl, 'public-read') if SourceTypeS3 == destination[:type]
  		
  	end
  	def self.__init_input_ranges input
		input[:effects].each do |effect|
			effect[:range] = input[:range]
		end
		input[:merger][:range] = input[:range] if input[:merger] 	
		input[:scaler][:range] = input[:range] if input[:scaler]
  	end
	def self.__init_clip_media clip, mash
		if clip[:id] then
			media = mash_search mash, clip[:id]
			if media then
				media.each do |k,v|
					clip[k] = v unless clip[k]
				end 
			else
				media = Marshal.load(Marshal.dump(clip))
				mash[:media] << media
			end
		end
	end
	def self.__init_input input
		__init_time input, :trim
		__init_key input, :start, FLOAT_NEG_ONE
		__init_key input, :track, 0
		__init_key input, :duration, FLOAT_ZERO
		__init_key(input, :length, 1) if TypeImage == input[:type]
		__init_time input, :length # ^ image will already be one by default
		__init_raw_input input
		# this is done for real inputs during __set_timing
		__init_input_ranges input
		input
	end
	def self.__init_input_mash input
		if __is_a_mash? input[:source] then
			__init_mash input[:source]
			input[:duration] = __mash_duration(input[:source]) if float_cmp(input[:duration], FLOAT_ZERO)
			input[:no_audio] = ! __mash_has_audio?(input[:source])
			input[:no_video] = ! __mash_has_video?(input[:source])
		end
	end
	def self.__init_key output, key, default
		
		output[key] = default if ((not output[key]) or output[key].to_s.empty?)
#		if default.is_a?(Float) then
#			output[key] = output[key].to_f if 
#		else
#			output[key] = output[key].to_i if default.is_a?(Integer) 
#		end
	end
	def self.__init_mash mash
		mash[:quantize] = (mash[:quantize] ? mash[:quantize].to_f : FLOAT_ONE)
		mash[:media] = Array.new unless mash[:media] and mash[:media].is_a? Array
		mash[:tracks] = Array.new unless mash[:tracks] and mash[:tracks].is_a? Hash
		longest = FLOAT_ZERO
		TrackTypes.each do |track_type|
			track_sym = track_type.to_sym
			mash[:tracks][track_sym] = Array.new unless mash[:tracks][track_sym] and mash[:tracks][track_sym].is_a? Array
			tracks = mash[:tracks][track_sym]
			track_index = 0
			tracks.each do |track|
				track[:clips] = Array.new unless track[:clips] and track[:clips].is_a? Array
				track[:clips].each do |clip|
					__init_clip clip, mash, track_index, track_type
					__init_clip_media(clip[:merger], mash) if clip[:merger]
					__init_clip_media(clip[:scaler], mash) if clip[:scaler]
					clip[:effects].each do |effect|
						__init_clip_media effect, mash
					end
				end
				clip = track[:clips].last
				if clip then
					longest = float_max(longest, clip[:range].get_end)
				end
				track_index += 1
			end
		end
		mash[:length] = longest
	end
	def self.__init_output output, job_identifier = nil
		__init_key output, :type, TypeVideo
		output[:desires] = __output_desires output
		output[:filter_graphs] = Hash.new
		output[:filter_graphs][:video] = Array.new unless AVAudio == output[:desires]
		output[:filter_graphs][:audio] = Array.new unless AVVideo == output[:desires]
		output[:job_identifier] = job_identifier
		output[:identifier] = UUID.new.generate
		__init_key output, :name, ((TypeSequence == output[:type]) ? '{output.sequence}' : output[:type])
		__init_key output, :switches, ''
		case output[:type]
		when TypeVideo
			__init_key output, :backcolor, 'black'
			__init_key output, :fps, 30
			__init_key output, :precision, 1
			__init_key output, :extension, 'flv'
			__init_key output, :video_codec, 'flv'
			__init_key output, :audio_bitrate, 224
			__init_key output, :audio_codec, 'libmp3lame'
			__init_key output, :dimensions, '512x288'
			__init_key output, :fill, MASH_FILL_NONE
			__init_key output, :gain, MASH_VOLUME_NONE
			__init_key output, :audio_frequency, 44100
			__init_key output, :video_bitrate, 4000
		when TypeSequence
			__init_key output, :backcolor, 'black'
			__init_key output, :fps, 10
			__init_key output, :begin, 1
			__init_key output, :increment, 1
			__init_key output, :extension, 'jpg'
			__init_key output, :dimensions, '256x144'
			__init_key output, :quality, 1
			output[:no_audio] = true
		when TypeImage
			__init_key output, :backcolor, 'black'
			__init_key output, :quality, 1						
			__init_key output, :fps, 1							
			__init_key output, :extension, 'jpg'
			__init_key output, :dimensions, '256x144'
			output[:no_audio] = true
		when TypeAudio
			__init_key output, :audio_bitrate, 224
			__init_key output, :precision, 0
			__init_key output, :audio_codec, 'libmp3lame'
			__init_key output, :extension, 'mp3'
			__init_key output, :audio_frequency, 44100
			__init_key output, :gain, MASH_VOLUME_NONE
			output[:no_video] = true
		when TypeWaveform
			__init_key output, :backcolor, 'FFFFFF'
			__init_key output, :dimensions, '8000x32'
			__init_key output, :forecolor, '000000'
			__init_key output, :extension, 'png'
			output[:no_video] = true
		end
		output				
	end
	def self.__init_raw_input input
	
		input[:effects] = Array.new unless input[:effects] and input[:effects].is_a? Array
		input[:merger] = __filter_merger_default unless input[:merger]
		input[:scaler] = __filter_scaler_default unless input[:scaler] or input[:fill]
		
		input_type = input[:type]
		is_av = [TypeVideo, TypeAudio].include? input_type
		is_v = [TypeVideo, TypeImage, TypeFrame].include? input_type
		
		# set volume with default of none (no adjustment)
		__init_key(input, :gain, MASH_VOLUME_NONE) if is_av
		__init_key(input, :fill, MASH_FILL_STRETCH) if is_v
		
		# set source from url unless defined
		case input_type
		when TypeVideo, TypeImage, TypeFrame, TypeAudio
			input[:source] = input[:url] unless input[:source]
			if input[:source].is_a? Hash then
				__init_key(input[:source], :type, 'http')
			end
		end		
		
		# set no_* when we know for sure
		case input_type
		when TypeMash
			__init_input_mash input
		when TypeVideo
			input[:speed] = (input[:speed] ? FLOAT_ONE : input[:speed].to_f) 
			input[:no_audio] = ! float_cmp(FLOAT_ONE, input[:speed])
			input[:no_video] = false
		when TypeAudio
			__init_key input, :loop, 1
			input[:no_video] = true
		when TypeImage
			input[:no_video] = false
			input[:no_audio] = true
		else
			input[:no_audio] = true
		end		
		input[:no_audio] = ! __clip_has_audio(input) if is_av and not input[:no_audio]
		input
	end
	def self.__init_time input, key
		if input[key] then
			if input[key].is_a? String then
				input["#{key.id2name}_is_relative".to_sym] = '%'
				input[key]['%'] = ''
			end
			input[key] = input[key].to_f
			if float_gtr(FLOAT_ZERO, input[key]) then
				input["#{key.id2name}_is_relative".to_sym] = '-'
				input[key] = FLOAT_ZERO - input[key]
			end
		else 
			input[key] = FLOAT_ZERO
		end
	end
	def self.__input_dimensions
		dimensions = nil
		found_mash = false
		@@job[:inputs].each do |input|
			case input[:type]
			when TypeMash
				found_mash = true
			when TypeImage, TypeVideo
				dimensions = input[:dimensions]
			end
			break if dimensions
		end
		dimensions = -1 if ((! dimensions) && found_mash) 
		dimensions
	end
	def self.__input_has input
		case input[:type]
		when TypeAudio
			AVAudio
		when TypeImage
			AVVideo
		when TypeVideo, TypeMash
			(input[:no_audio] ? AVVideo : input[:no_video] ? AVAudio : AVBoth)
		end
	end
	def self.__input_url input, base_source = nil
		url = nil
		if input[:source] then
			if input[:source].is_a? String then
				url = input[:source]
				if not url.include? '://' then
					# relative url
					base_url = __source_url base_source
					if base_url then
						base_url += '/' unless base_url.end_with? '/'
						url = URI.join(base_url, url).to_s
					end
				end
			elsif input[:source].is_a? Hash then
				url = __source_url input[:source]
			end
		end
		url
	end
	def self.__is_a_mash? hash
		isa = false
		if hash.is_a?(Hash) and hash[:media] and hash[:media].is_a?(Array) then
			if hash[:tracks] and hash[:tracks].is_a? Hash then
				if hash[:tracks][:video] and hash[:tracks][:video].is_a? Array then
					isa = true
				end
			end
		end
		isa
	end
	def self.__mash_clips_having_audio mash
		clips = Array.new
		TrackTypes.each do |track_type|
			mash[:tracks][track_type.to_sym].each do |track|
				track[:clips].each do |clip|
					#raise "WTF #{clip.inspect}" if clip[:no_audio] == __clip_has_audio(clip)
					clips << clip unless clip[:no_audio] or not __clip_has_audio(clip)
				end
			end
		end
		clips
	end
	def self.__mash_clips_in_range mash, range, track_type
		clips_in_range = Array.new
		#puts "__mash_clips_in_range #{range.inspect} #{mash[:tracks][track_type.to_sym].length}"
				
		mash[:tracks][track_type.to_sym].each do |track|
			#puts "__mash_clips_in_range clips length #{track[:clips].length}"
			track[:clips].each do |clip|
				if range.intersection(clip[:range]) then
					clips_in_range << clip 
				else
					#puts "__mash_clips_in_range #{range.inspect} #{clip[:range].inspect}"
				end
			end
		end
		clips_in_range.sort! { |a,b| ((a[:track] == b[:track]) ? (a[:frame] <=> b[:frame]) : (a[:track] <=> b[:track]))}
		clips_in_range
	end
	def self.__mash_duration mash
		mash[:length] / mash[:quantize]
	end
	def self.__mash_has_audio? mash
		TrackTypes.each do |track_type|
			mash[:tracks][track_type.to_sym].each do |track|
				track[:clips].each do |clip|
					return true if __clip_has_audio clip
				end
			end
		end
		false
	end
	def self.__mash_has_video? mash
		TrackTypes.each do |track_type|
			next if TrackTypeAudio == track_type
			mash[:tracks][track_type.to_sym].each do |track|
				track[:clips].each do |clip|
					return true
				end
			end
		end
		false
	end
	def self.__mash_trim_frame clip, start, stop, fps = 44100
		result = Hash.new
		fps = fps.to_i
		orig_clip_length = clip[:length]
		speed = clip[:speed].to_f
		media_duration = (clip[:duration] * fps.to_f).floor.to_i
		media_duration = clip[:length] if (media_duration <= 0) 
		media_duration = (media_duration.to_f * speed).floor.to_i
		orig_clip_start = clip[:start]
		unless TypeVideo == clip[:type] and 0 == clip[:track] then
			start -= orig_clip_start
			stop -= orig_clip_start
			orig_clip_start = 0
		end
		orig_clip_end = orig_clip_length + orig_clip_start
		clip_start = [orig_clip_start, start].max
		clip_length = [orig_clip_end, stop].min - clip_start
		orig_clip_trimstart = clip[:trim] || 0
		clip_trimstart = orig_clip_trimstart + (clip_start - orig_clip_start)
		clip_length = [clip_length, media_duration - clip_trimstart].min if 0 < media_duration 
		result[:offset] = 0
		if 0 < clip_length then
			result[:offset] = (clip_start - orig_clip_start)
			result[:trimstart] = clip_trimstart
			result[:trimlength] = clip_length
		end
		result
	end
	def self.__mash_video_ranges mash
		quantize = mash[:quantize]
		frames = Array.new
		frames << 0
		frames << mash[:length]
		mash[:tracks][:video].each do |track|
			track[:clips].each do |clip|
				frames << clip[:range].frame
				frames << clip[:range].get_end
			end
		end
		all_ranges = Array.new
		
		frames.uniq!
		frames.sort!
		#puts "__mash_video_ranges #{frames}"
		frame = nil
		frames.length.times do |i|
			#raise "got out of sequence frames #{frames[i]} <= #{frame}" unless frames[i] > frame
			#puts "__mash_video_ranges #{i} #{frame} #{frames[i]}"
			all_ranges << FrameRange.new(frame, frames[i] - frame, quantize) if frame
			frame = frames[i]
		end
		all_ranges
	end
	def self.__output_command output, av_type, duration = nil
		cmd = ''
		unless AVVideo == av_type then # we have audio output
			cmd += __cache_switch(output[:audio_bitrate], 'b:a', 'k') if output[:audio_bitrate]
			cmd += __cache_switch(output[:audio_frequency], 'ar') if output[:audio_frequency]
			cmd += __cache_switch(output[:audio_codec], 'c:a') if output[:audio_codec]
		end
		unless AVAudio == av_type then # we have visual output
			case output[:type]
			when TypeVideo
				cmd += __cache_switch(output[:dimensions], 's') if output[:dimensions]
				cmd += __cache_switch(output[:video_format], 'f:v') if output[:video_format]
				cmd += __cache_switch(output[:video_codec], 'c:v') if output[:video_codec]
				cmd += __cache_switch(output[:video_bitrate], 'b:v', 'k') if output[:video_bitrate]
				cmd += __cache_switch(output[:fps], 'r') if output[:fps]
			when TypeImage
				cmd += __cache_switch(output[:quality], 'quality') if output[:quality]
			when TypeSequence
				cmd += __cache_switch(output[:quality], 'quality') if output[:quality]
				cmd += __cache_switch(output[:fps], 'r') if output[:fps]
			end
		end
		cmd
	end
	def self.__output_desires output
		case output[:type]
		when TypeAudio, TypeWaveform
			AVAudio
		when TypeImage, TypeSequence
			AVVideo
		when TypeVideo
			AVBoth
		end
	end
	def self.__output_intermediate
		output = Hash.new 
		output[:type] = TypeVideo
		output[:video_format] = PIPE_VIDEO_FORMAT
		output[:extension] = PIPE_VIDEO_EXTENSION
		output
		#final_output
	end
	def self.__output_path output, index = nil
		#puts "__output_path name = #{output[:name]}"
				
		out_file = output_path output
		__transfer_file_name output, out_file, index
	end
	def self.__render_path output
		raise "__render_path called with no job processing" unless @@job
		destination = output[:destination] || @@job[:destination]
		out_file = CONFIG['dir_temporary']
		out_file += '/' unless out_file.end_with? '/'
		out_file += @@job[:identifier] + '/'
		out_file += destination[:identifier] + '/'
		out_file += __render_path_partial output
		out_file
	end
	def self.__render_path_partial options
		dirs = Array.new
		dirs << options[:directory] if options[:directory]
		path = options[:path]
		unless path
			path = options[:name]
			path += '.' + options[:extension] if options[:extension]
		end
		dirs << path
		path = dirs.join '/'
		__eval_value path
	end
	def self.__set_timing
		start_audio = FLOAT_ZERO
		start_video = FLOAT_ZERO
		@@job[:inputs].each do |input|
			if float_cmp(input[:start], FLOAT_NEG_ONE) then
				unless (input[:no_video] or input[:no_audio]) then
					input[:start] = [start_audio, start_video].max
				else
					if input[:no_video] then
						input[:start] = start_audio
					else 
						input[:start] = start_video
					end
				end
			end	
			start_video = input[:start] + __get_length(input) unless input[:no_video]
			start_audio = input[:start] + __get_length(input) unless input[:no_audio]
			input[:range] = __get_trim_range_simple(input)
			__init_input_ranges input
		end
		output_duration = float_max(start_video, start_audio)
		@@job[:duration] = output_duration
		@@job[:outputs].each do |output|
			output[:duration] = output_duration
			if TypeSequence == output[:type] then
				padding = (output[:begin] + (output[:increment].to_f * output[:fps].to_f * output_duration).floor.to_i).to_s.length
				output[:sequence] = "%0#{padding}d"
			end
		end
	end
	def self.__shell_command cmd
		#puts cmd
		stdin, stdout, stderr = Open3.capture3 cmd
		#puts "stdin #{stdin}"
		#puts "stdout #{stdout}"
		#puts "stderr #{stderr}"
		output = stdin.to_s + "\n" + stdout.to_s + "\n" + stderr.to_s
		#puts output
		output
	end
	def self.__source_from_uri uri
		source = Hash.new
		source[:type] = uri.scheme #=> "http"
		source[:host] = uri.host #=> "foo.com"
		source[:path] = uri.path #=> "/posts"
		source[:port] = uri.port
		#uri.query #=> "id=30&limit=5"
		#uri.fragment #=> "time=1305298413"
		source
	end
	def self.__source_url source
		url = nil
		if source then
			if source[:url] then
				url = source[:url]
			else
				url = "#{source[:type]}://"
				case source[:type]
				when SourceTypeFile
					url += __directory_path_name source
				when SourceTypeHttp, SourceTypeHttps
					url += source[:host] if source[:host]
					path = __directory_path_name source
					url += '/' unless path.start_with? '/'
					url += path
				when SourceTypeS3
					url += "#{source[:bucket]}." if source[:bucket]
					url += 's3'
					url += "-#{source[:region]}" if source[:region]
					url += '.amazonaws.com'
					path = __directory_path_name source
					url += '/' unless path.start_with? '/'
					url += path
				else
					url = nil
				end
			end
		end
		url
	end
	def self.__sqs
		(CONFIG['queue_region'] ? AWS::SQS.new(:region => CONFIG['queue_region']) : AWS::SQS.new)
	end
	def self.__sqs_request run_seconds, start
		unless @@queue then
			sqs = __sqs
			# queue will be nil if their URL is not defined in config.yml
			@@queue = sqs.queues[CONFIG['queue_url']]
		end
		if @@queue and run_seconds > (Time.now + QueueReceiveMessagesWaitTime - start) then
			message = @@queue.receive_message(:wait_time_seconds => QueueReceiveMessagesWaitTime)
			if message then
				job = nil
				begin
					job = JSON.parse(message.body)
					begin
						job['id'] = message.id unless job['id']
						File.open("#{CONFIG['dir_queue']}/#{message.id}.json", 'w') { |file| file.write(job.to_json) } 
						message.delete
					rescue Exception => e
						LOG.error{ "Job could not be written to: #{CONFIG['dir_queue']}" }
					end
				rescue Exception => e
					LOG.error{ "Job could not be parsed as json: #{message.body}" }
					message.delete
				end
			end
		end
	end
	def self.__s3 source
		(source[:region] ? AWS::S3.new(:region => source[:region]) : AWS::S3.new)
	end
	def self.__s3_bucket source
		s3 = __s3 source
		s3.buckets[source[:bucket]]
	end
	def self.__transfer_file mode, source_path, out_file
		source_path = "/#{source_path}" unless source_path.start_with? '/'
		out_file = "/#{out_file}" unless out_file.start_with? '/'
		case mode
		when SourceModeSymlink
			FileUtils.symlink source_path, out_file
		when SourceModeCopy
			FileUtils.copy source_path, out_file
		when SourceModeMove
			FileUtils.move source_path, out_file
		end
		raise "could not #{mode} #{source_path} to #{out_file}" unless File.exists? out_file
	rescue 
		puts "could not #{mode} #{source_path} to #{out_file}"
		raise
	end
	def self.__transfer_file_from_data file
		unless file.is_a? String then
			file_path = "#{output_path @@job}#{UUID.new.generate}.json"
			File.open(file_path, 'w') { |f| f.write(file.to_json) }
			file = file_path
		end
		file
	end
	def self.__transfer_file_destination file, destination
		if file then
			if file.is_a? String then
				if not File.exists?(file) then
					@@job[:warnings] << "file was not rendered #{file}"
					return
				end
				# just use directory if we output a sequence
				file = File.dirname(file) + '/' if file.include? '%'
			end
		end
		destination_path = __directory_path_name destination
		destination_path = File.dirname(destination_path) + '/' if destination_path.include? '%'
		case destination[:type]
		when SourceTypeFile
			FileUtils.mkdir_p(File.dirname(destination_path))
			destination[:file] = destination_path
			if file then
				file = __transfer_file_from_data file
				__transfer_file destination[:mode], file, destination_path
			end
		when SourceTypeS3
			if file then
				file = __transfer_file_from_data file
				#puts "__transfer_file_destination #{file} #{destination_path}"
				files = Array.new
				uploading_directory = File.directory?(file)
				if uploading_directory then
					file += '/' unless file.end_with? '/'
					Dir.entries(file).each do |f|
						f = file + f
						files << f unless File.directory?(f)
					end
				else 
					files << file
				end
				files.each do |file|
					bucket_key = destination_path
					bucket_key += File.basename(file) if bucket_key.end_with? '/'
					mime_type = __cache_get_info file, 'Content-Type'
					bucket = __s3_bucket destination
					puts "destination: #{destination.inspect}"
					puts "bucket_key: #{bucket_key}"
					bucket_object = bucket.objects[bucket_key]
					options = Hash.new
					options[:acl] = destination[:acl].to_sym if destination[:acl]
					options[:content_typ] = mime_type
					puts "write options: #{options}"
					bucket_object.write(Pathname.new(file), options)
				end
			end
		when SourceTypeHttp, SourceTypeHttps
			url = "#{destination[:type]}://#{destination[:host]}"
			path = __directory_path_name destination
			url += '/' unless path.start_with? '/'
			url += path
			uri = URI(url)
			uri.port = destination[:port].to_i if destination[:port]
			req = nil
			io = nil
			if file then
				if file.is_a? String then
					file_name = File.basename file
					io = File.open(file)
					mime_type = __cache_get_info file, 'Content-Type'
					req = Net::HTTP::Post::Multipart.new(uri.path, "key" => path, "file" => UploadIO.new(io, mime_type, file_name)) if io
				else # json request
					req = Net::HTTP::Post.new(uri)
					LOG.info{"JSON POST #{file.to_json}"}
					req.body = file.to_json
				end
			else # simple get request
				req = Net::HTTP::Get.new(uri)
			end
			if req then
				req.basic_auth(destination[:user], destination[:pass]) if destination[:user] and destination[:pass]
				res = Net::HTTP.start(uri.host, uri.port, :use_ssl => (uri.scheme == 'https')) do |http|
					result = http.request(req)
					LOG.info {"#{result.body}"}
				end
				io.close if io 
			end
		end
	end
	def self.__transfer_file_name source, url, index = nil	
		name = source[:name] || ''
		if TypeSequence == source[:type] then # only true for sequence outputs
			padding = (1 + (source[:fps].to_f * source[:duration]).floor).to_s.length
			name += "%0#{padding}d"
		else
		end
		if name and not name.empty? then
			url += '/' unless url.end_with? '/'
			url += name
			url += '-' + index.to_s if index
			url += '.' + source[:extension] if source[:extension]
		end
		__eval_value url
	end
	def self.__transfer_job_output output
		if output[:rendering] then
			@@output = output
			destination = output[:destination] || @@job[:destination]
			raise "output #{output[:identifier]} has no destination" unless destination 
			file = output[:rendering]
			if destination[:archive] || output[:archive] then
				raise "TODO: __transfer_job_output needs support for archive option"
			end
			__transfer_file_destination file, destination
			@@output = nil
			
		else
			raise "output #{output[:identifier]} was not generated" if output[:required]
		end
	end
	def self.__trigger type
		dont_trigger = false
		unless :progress == type then
			dont_trigger = @@job[:calledback][type]
			@@job[:calledback][type] = true unless dont_trigger
		end
		unless dont_trigger then
			type_str = type.id2name
			@@job[:callbacks].each do |callback|
				next unless type_str == callback[:trigger]
				data = callback[:data] || nil
				if data then
					if data.is_a? Hash then
						data = Marshal.load(Marshal.dump(data)) 
						__eval_hash_recursively data
					else # only arrays and hashes supported
						data = nil unless data.is_a? Array 
					end
				end
				__transfer_file_destination data, callback
			end
		end
	end
end
