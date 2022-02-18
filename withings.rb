#!/usr/bin/env ruby
# frozen_string_literal: true

require 'rubygems'
require 'bundler/setup'
Bundler.require(:default)

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
}.freeze

class Withings < RecorderBotBase
  desc 'authorize', 'authorize this application, and authenticate with the service'
  def authorize
    credentials = load_credentials
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
    store_credentials credentials

    puts 'authorization successful'
  end

  no_commands do
    def main
      credentials = load_credentials

      influxdb = InfluxDB::Client.new 'withings' unless options[:dry_run]

      with_rescue([NoMethodError], logger) do |_try|
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
                    store_credentials credentials

                    date = Date.today
                    meastype = MEASURE_TYPES.keys.join(',')
                    client.get("/measure?action=getmeas&category=1&startdate=#{date.next_day(-7).to_time.to_i}&enddate=#{date.next_day(1).to_time.to_i - 1}&meastype=#{meastype}")
                  end

        data = []
        records['body']['measuregrps'].each do |grp|
          timestamp = grp['date']
          grp['measures'].each do |measure|
            value = measure['value'].to_f * 10**measure['unit']
            name = MEASURE_TYPES[measure['type']]
            logger.debug "#{Time.at(timestamp)} #{name} = #{value}"
            data.push({ series: name, values: { value: value }, timestamp: timestamp })
          end
        end
        influxdb.write_points data unless options[:dry_run]
      end
    end
  end
end

Withings.start
