module MovieMasher
	class FilterHelpers
		def self.mm_horz param_string, scope
			params = __params_from_str param_string, scope
			param_string = params.join(',')
			param_sym = param_string.to_sym
			if scope[param_sym] then
				(scope[:mm_width].to_f * scope[param_sym].to_f).round.to_i.to_s
			else
				"(#{scope[:mm_width]}*#{param_string})"
			end
		end
		def self.mm_vert param_string, scope
			params = __params_from_str param_string, scope
			param_string = params.join(',')
			param_sym = param_string.to_sym
			if scope[param_sym] then
				(scope[:mm_height].to_f * scope[param_sym].to_f).round.to_i.to_s
			else
				"(#{scope[:mm_height]}*#{param_string})"
			end
		end
		def self.mm_dir_horz param_string, scope
			raise "mm_dir_horz no parameters #{param_string}" if param_string.empty?
			params = __params_from_str param_string, scope
			#puts "mm_dir_horz #{param_string}} #{params.join ','}"
			case params[0].to_i # direction value
			when 0, 2 # center with no change
				"((in_w-out_w)/2)"
			when 1, 4, 5
				"((#{params[2]}-#{params[1]})*#{params[3]})"
			when 3, 6, 7
				"((#{params[1]}-#{params[2]})*#{params[3]})"
			else 
				raise "unknown direction #{params[0]}"
			end
		end
		def self.mm_paren param_string, scope
			params = __params_from_str param_string, scope
			"(#{params.join ','})"
		end
		def self.mm_dir_vert param_string, scope
			raise "mm_dir_vert no parameters #{param_string}" if param_string.empty?
			params = __params_from_str param_string, scope
			#puts "mm_dir_vert #{param_string} #{params.join ','}"
			result = case params[0].to_i # direction value
			when 1, 3 # center with no change
				"((in_h-out_h)/2)"
			when 0, 4, 7
				"((#{params[1]}-#{params[2]})*#{params[3]})"
			when 2, 5, 6
				"((#{params[2]}-#{params[1]})*#{params[3]})"
			else 
				raise "unknown direction #{params[0]}"
			end
			result
		end
		def self.mm_max param_string, scope
			params = __params_from_str param_string, scope
			params.max
		end
		def self.mm_times param_string, scope
			params = __params_from_str param_string, scope
			total = FLOAT_ONE
			params.each do |param|
				total *= param.to_f
			end
			total
		end
		def self.mm_min param_string, scope
			params = __params_from_str param_string, scope
			params.min
		end
		def self.mm_cmp param_string, scope
			params = __params_from_str param_string, scope
			(params[0].to_f > params[1].to_f ? params[2] : params[3])
		end
		def self.__params_from_str param_string, scope
			(param_string.is_a?(String) ? param_string.split(',') : param_string)
		end
	end
end