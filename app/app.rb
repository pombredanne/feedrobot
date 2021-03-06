require 'sinatra/base'
require 'rack-superfeedr'
require 'omniauth'
require 'omniauth-appdotnet'
require 'multi_json'
require_relative 'adn.rb'
require_relative 'models.rb'
require_relative 'const.rb'

class FeedRobot < Sinatra::Base
  set :session_secret, SESSION_SECRET
  set :server, :thin

  configure :production do
    require 'newrelic_rpm'
  end
  use Rack::Session::Cookie, :secret => settings.session_secret
  use OmniAuth::Builder do
    provider :appdotnet, ADN_ID, ADN_SECRET, :scope => 'files,messages,follow,stream'
  end
  use Rack::Superfeedr, {:host => HOST, :login => SUPERFEEDR_LOGIN, :password => SUPERFEEDR_PASSWORD,
                         :format => "json", :async => false} do |superfeedr|
    $superfeedr = superfeedr

    superfeedr.on_notification do |notification|
      url = notification['status']['id'] || notification['status']['feed'] # Atom || RSS
      puts "Notification for feed #{url}"
      feed = Feed.find(:url => url).first
      if feed && notification['items'] # Parse errors don't have items
        notification['items'].each do |item|
          permalink = item['permalinkUrl']
          unless Ohm.redis.sismember 'sent', permalink
            feed.users.each do |user|
              ADN.global.send_pm :destinations => [user.uid], :text => "#{item['title']}: #{permalink}"
            end
            Ohm.redis.sadd 'sent', permalink
          end
        end
        Ohm.redis.expire 'sent', 60*10
      else
        puts "Feed not found"
      end
    end
  end

  before do
    @adn = ADN.new session[:token]
    @me = @adn.me unless session[:token].nil?
  end

  not_found do
    "404"
  end

  get '/auth/appdotnet/callback' do
    session[:token] = request.env['omniauth.auth']['credentials']['token']
    redirect request.env['omniauth.origin'] || '/'
  end

  get '/auth/logout' do
    session[:token] = nil
    redirect '/'
  end

  get '/' do
    "hello :-)"
  end

  get '/subscriptions/:uid/:secret' do
    user = User.find(:uid => params[:uid]).first
    halt 404 unless user && user.secret == params[:secret]
    list = user.feeds.map(&:url).map { |u| "<li><a href='#{u}'>#{u}</a></li>" }.join "\n"
    "<!DOCTYPE html><ul>#{list}</ul>"
  end

  get TOKEN_URL do
    if @me.nil?
      "<form method=post action='/auth/appdotnet'><button type=submit>get token</button></form>"
    else
      "token: #{session[:token]} -- <a href='/auth/logout'>log out</a>"
    end
  end
end
