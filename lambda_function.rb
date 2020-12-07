require 'aws-sdk-s3'
require 'pp'
require "open-uri"
require 'active_support/all'
require 'base64'
require 'digest/md5'
require 'openssl'
require 'net/http'

def lambda_handler(event:, context:)
  # 画像版のWeb魚拓
  # 画像が存在するなら最新のものを表示したいので、そのまま表示
  # 画像がない場合、s3に画像があれば表示
  query_string_parameters = event["queryStringParameters"]
  # getパラメーターがない場合は404
  return json_404 if query_string_parameters.nil?

  image_url = query_string_parameters["image_url"]
  # image_urlパラメーターがない場合は404
  return json_404 if image_url.nil?

  # image_url=(CGI.escapeでurlエンコードした画像url)でリクエストしているが
  # どうやらdecodeしなくても、lambdaのproxy側で勝手にデコードされている模様
  region = ENV['REGION']
  aws_access_key_id = ENV['ACCESS_KEY']
  aws_secret_access_key = ENV['SECRET_ACCESS_KEY']
  bucket_name = ENV['BUCKET_NAME']

  bucket = Aws::S3::Resource.new(
    :region => region,
    :access_key_id => aws_access_key_id,
    :secret_access_key => aws_secret_access_key
  ).bucket(bucket_name)

  object_key = Digest::MD5.hexdigest(image_url)

  response_headers = nil
  response = nil

  begin
    uri = URI.parse(image_url)
    response = Net::HTTP.get_response(uri)
    response_headers = response.each_header.to_h

    # 大きすぎる画像はlambdaが表示できないみたいなので301
    # headリクエストしたいがheadリクエストをnginxで受け付けてない場合もあるので普通にリクエスト
    if response_headers["content-length"].to_i > 6291556
      return json_301(url: image_url)
    end
  rescue
    # 画像がexpiredなどで403が出たり、404だったりで存在しない場合
  end

  if ! response.nil?
    # 画像がある場合はそちらを表示。最新のものを表示したいのでs3のキャッシュは表示しない方針
    # s3に保存するかどうかは条件分岐
    image_binary = response.body

    s3_save = false

    request_digest_hex = query_string_parameters["d"]

    if ! request_digest_hex.nil?
      digest_head_key = ENV['DIGEST_HEAD_KEY']
      data = "#{digest_head_key}:#{Time.now.utc.strftime("%Y%m%d")}"
      digest_hex = Digest::SHA1.hexdigest(data)
      # digestが一致してない場合はs3に保存できない
      if digest_hex == request_digest_hex
        if ! bucket.object(object_key).exists?
          # s3に画像がない場合は保存
          s3_save = true
        else
          # s3に画像があるが古い場合は保存
          object_data = bucket.object(object_key)
          last_modified = object_data.get.last_modified
          if last_modified.to_time <= Time.now - 1.days
            s3_save = true
          end
        end
      end
    end

    bucket.object(object_key).put(:body => image_binary) if s3_save
    headers = {
      'Content-Type': response_headers["content-type"].presence || 'image/jpeg',
      'X-IMProxy-Cache-Hits': 'MISS',
      'Etag': response_headers["etag"],
      'Last-Modified': response_headers["last-modified"],
      'Date': response_headers["date"],
      'Expires': response_headers["expires"],
    }
    return json_200(image_binary: image_binary, headers: headers)
  end

  # 画像がない場合
  # s3にあればそれを表示。なければ404
  if bucket.object(object_key).exists?
    object_data = bucket.object(object_key)
    image_binary = object_data.get.body.read
    # 元画像が存在しないが、s3の画像を表示した場合はX-IMProxy-Cache-HitsがHIT

    s3_info = object_data.get.to_h

    headers = {
      'Content-Type': 'image/jpeg',
      'X-IMProxy-Cache-Hits': 'HIT',
      'Etag': s3_info[:etag],
      'Last-Modified': s3_info[:last_modified],
    }
    return json_200(image_binary: image_binary, headers: headers)
  end

  # 画像がない場合は404返して終了
  return json_404
end

def json_404
  {
    statusCode: 404,
    headers: { 'Content-Type': 'image/jpeg' },
    body: nil,
    isBase64Encoded: true,
  }
end

def json_200(image_binary:, headers:)
  {
    statusCode: 200,
    headers: headers,
    body: Base64.strict_encode64(image_binary),
    isBase64Encoded: true,
  }
end

def json_301(url:)
  {
    statusCode: 301,
    headers: {"Location": url},
    body: nil
  }
end

def json_debug(data:)
  {
    statusCode: 200,
    body: data.to_json
  }
end