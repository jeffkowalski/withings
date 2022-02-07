#!/usr/bin/env ruby
# frozen_string_literal: true

require 'fileutils'
require 'influxdb'
require 'logger'
require 'thor'
require 'withings_api_oauth2'
require 'yaml'

LOGFILE = File.join(Dir.home, '.log', 'withings.log')
CREDENTIALS_PATH = File.join(Dir.home, '.credentials', 'withings.yaml')

module Kernel
  def with_rescue(exceptions, logger, retries: 5)
    try = 0
    begin
      yield try
    rescue *exceptions => e
      try += 1
      raise if try > retries

      logger.info "caught error #{e.class}, retrying (#{try}/#{retries})..."
      retry
    end
  end
end

MEASURE_TYPES = {
  1   => 'weight', # Weight (kg)
  4   => 'height', # Height (meter)
  5   => 'fat_free_mass', # Fat Free Mass (kg)
  6   => 'fat_ratio', # Fat Ratio (%)
  8   => 'fat_mass_weight', # Fat Mass Weight (kg)
  9   => 'diastolic_blood_pressure', # Diastolic Blood Pressure (mmHg)
  10  => 'systolic_blood_pressure', # Systolic Blood Pressure (mmHg)
  11  => 'heart_rate', # Heart Pulse (bpm) - only for BPM and scale devices
  12  => 'temperature', # Temperature (celsius)
  54  => 'spo2', # SP02 (%)
  71  => 'body_temperature', # Body Temperature (celsius)
  73  => 'skin_temperature', # Skin Temperature (celsius)
  76  => 'muscle_mass', # Muscle Mass (kg)
  77  => 'hydration', # Hydration (kg)
  88  => 'bone_mass', # Bone Mass (kg)
  91  => 'pulse_wave_velocity', # Pulse Wave Velocity (m/s)
  123 => 'vo2_max', # VO2 max is a numerical measurement of your body's ability to consume oxygen (ml/min/kg).
  135 => 'qrs_interval_duration', # QRS interval duration based on ECG signal
  136 => 'pr_interval_duration', # PR interval duration based on ECG signal
  137 => 'qt_interval_duration', # QT interval duration based on ECG signal
  138 => 'corrected_qt_interval_duration', # Corrected QT interval duration based on ECG signal
  139 => 'atrial_fibrillation' # Atrial fibrillation result from PPG
}

class Withings < Thor
  no_commands do
    def redirect_output
      unless LOGFILE == 'STDOUT'
        logfile = File.expand_path(LOGFILE)
        FileUtils.mkdir_p(File.dirname(logfile), mode: 0o755)
        FileUtils.touch logfile
        File.chmod 0o644, logfile
        $stdout.reopen logfile, 'a'
      end
      $stderr.reopen $stdout
      $stdout.sync = $stderr.sync = true
    end

    def setup_logger
      redirect_output if options[:log]

      @logger = Logger.new $stdout
      @logger.level = options[:verbose] ? Logger::DEBUG : Logger::INFO
      @logger.info 'starting'
    end
  end

  class_option :log,     type: :boolean, default: true, desc: "log output to #{LOGFILE}"
  class_option :verbose, type: :boolean, aliases: '-v', desc: 'increase verbosity'

  desc 'authorize', 'authorize this application, and authenticate with the service'
  def authorize
    credentials = YAML.load_file CREDENTIALS_PATH
    client = WithingsAPIOAuth2::Client.new(client_id: credentials[:client_id],
                                           client_secret: credentials[:client_secret],
                                           redirect_uri: credentials[:callback_url])

    puts 'Log in here:', client.auth_url
    puts 'Then paste the URL where the browser is redirected:'
    url = $stdin.gets.chomp
    # url = 'http://example.com/handle/callback?code=...&state=dummystate'
    code = url[/code=([^&#]+)/, 1]
    # puts code

    token = client.get_token(code)

    credentials[:user_id] = token.params['userid']
    credentials[:access_token] = token.token
    credentials[:refresh_token] = token.refresh_token
    credentials[:expires_at] = token.expires_at
    File.open(CREDENTIALS_PATH, 'w') { |file| file.write(credentials.to_yaml) }

    puts 'authorization successful'
  end

  desc 'record-status', 'record the current data to database'
  method_option :dry_run, type: :boolean, aliases: '-d', desc: 'do not write to database'
  def record_status
    setup_logger

    begin
      credentials = YAML.load_file CREDENTIALS_PATH

      influxdb = InfluxDB::Client.new 'withings' unless options[:dry_run]

      with_rescue([NoMethodError], @logger) do |_try|
        records = begin
                    client = WithingsAPIOAuth2::Client.new(client_id: credentials[:client_id],
                                                           client_secret: credentials[:client_secret],
                                                           access_token: credentials[:access_token],
                                                           refresh_token: credentials[:refresh_token],
                                                           expires_at: credentials[:expires_at],
                                                           user_id: credentials[:user_id])
                    token = client.token
                    credentials[:access_token] = token.token
                    credentials[:refresh_token] = token.refresh_token
                    credentials[:expires_at] = token.expires_at
                    File.open(CREDENTIALS_PATH, 'w') { |file| file.write(credentials.to_yaml) }

                    date = Date.today
                    meastype = MEASURE_TYPES.keys.join(',')
                    client.get("/measure?action=getmeas&category=1&startdate=#{date.next_day(-7).to_time.to_i}&enddate=#{(date.next_day(1).to_time.to_i - 1)}&meastype=#{meastype}")
                  end

        data = []
        records['body']['measuregrps'].each do |grp|
          timestamp = grp['date']
          grp['measures'].each do |measure|
            value = measure['value'].to_f * 10**measure['unit']
            name = MEASURE_TYPES[measure['type']]
            @logger.debug "#{Time.at(timestamp)} #{name} = #{value}"
            data.push({ series: name, values: { value: value }, timestamp: timestamp })
          end
        end
        influxdb.write_points data unless options[:dry_run]
      end
    rescue StandardError => e
      @logger.error e
    end
  end
end

Withings.start
