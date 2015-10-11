# Description:
#   send all of the messages on Slack in #timeline
#
# Configuration:
#   create #timeline channel on your Slack team
#
# Notes:
#   None
#
# Author:
#   vexus2

request = require 'request'
cloneDeep = require 'lodash.clonedeep'
cronJob = require('cron').CronJob

timezone = process.env.TZ ? ""

commands = ['setData', 'setLatestData']

module.exports = (robot) ->

  data = {}
  latestData = {}
  report = []
  loaded = false

  robot.brain.on "loaded", ->
    # "loaded" event is called every time robot.brain changed
    # data loading is needed only once after a reboot
    if !loaded
      try
        data = JSON.parse robot.brain.data.timelineSumup
        latestData = JSON.parse robot.brain.data.timelineSumupLatest
      catch error
        robot.logger.info("JSON parse error (reason: #{error})")
      #latestData = cloneDeep data
      enableReport()
    loaded = true

  sumUpMessagesPerChannel = (channel) ->
    echannel = escape channel

    if !data
      data = {}
    if !data[echannel]
      data[echannel] = 0
    data[echannel]++
    #robot.logger.info("sumUp:#{JSON.stringify(data)}")

    # wait robot.brain.set until loaded avoid destruction of data
    if loaded
      robot.brain.data.timelineSumup = JSON.stringify data

  score = ->
    # culculate diff between data and latestData
    diff = {}
    for key, value of data
      if !latestData[key]
        latestData[key] = 0
      if (value - latestData[key]) > 0
        diff[key] = value - latestData[key]

    # update latestData
    latestData = cloneDeep data
    robot.brain.data.timelineSumupLatest = JSON.stringify latestData

    # sort diff by value
    z = []
    for key,value of diff
      z.push([key,value])
    z.sort( (a,b) -> b[1] - a[1] )

    # display ranking
    if z.length > 0
      msgs = [ "いま話題のチャンネル(過去24時間の投稿数Top5@#timeline)" ]
      top5 = z[0..4]
      for msgsPerChannel in top5
        msgs.push(msgsPerChannel[0]+" ("+msgsPerChannel[1]+"件)")
      return msgs.join("\n")
    return ""

  enableReport = ->
    for job in report
      job.stop()
    report = []
    #timeline_channel = process.env.SLACK_TIMELINE_CHANNEL ? "timeline"
    report[report.length] = new cronJob "0 0 10 * * *", () ->
      robot.send { room: "general" }, score()
    , null, true, timezone

  # robot.respond /setData (.*)/, (msg) ->
  #   robot.brain.data.timelineSumup = msg.match[1]
  #   msg.send "set data"
  #   console.log robot.brain.data.timelineSumup

  # robot.respond /setLatestData (.*)/, (msg) ->
  #   robot.brain.data.timelineSumupLatest = msg.match[1]
  #   msg.send "set latestData"
  #   console.log robot.brain.data.timelineSumupLatest

  robot.hear /.*?/i, (msg) ->
    # for command in commands
    #   if (msg.message.text.indexOf(command) isnt -1)
    #     return

    channel = msg.envelope.room
    message = msg.message.text
    username = msg.message.user.name
    user_id = msg.message.user.id
    reloadUserImages(robot, user_id)
    user_image = robot.brain.data.userImages[user_id]
    if message.length > 0
      message = encodeURIComponent(message)
      link_names = if process.env.SLACK_LINK_NAMES then process.env.SLACK_LINK_NAMES else 0
      timeline_channel = if process.env.SLACK_TIMELINE_CHANNEL then process.env.SLACK_TIMELINE_CHANNEL else 'timeline'
      if channel is timeline_channel
        return
      request = msg.http("https://slack.com/api/chat.postMessage?token=#{process.env.SLACK_API_TOKEN}&channel=%23#{timeline_channel}&text=#{message}%20(at%20%23#{channel}%20)&username=#{username}&link_names=#{link_names}&pretty=1&icon_url=#{user_image}").get()
      request (err, res, body) ->
      sumUpMessagesPerChannel(channel)

  reloadUserImages = (robot, user_id) ->
    robot.brain.data.userImages = {} if !robot.brain.data.userImages
    robot.brain.data.userImages[user_id] = "" if !robot.brain.data.userImages[user_id]?

    return if robot.brain.data.userImages[user_id] != ""
    options =
      url: "https://slack.com/api/users.list?token=#{process.env.SLACK_API_TOKEN}&pretty=1"
      timeout: 2000
      headers: {}

    request options, (error, response, body) ->
      json = JSON.parse body
      i = 0
      len = json.members.length

      while i < len
        image = json.members[i].profile.image_48
        robot.brain.data.userImages[json.members[i].id] = image
        ++i


