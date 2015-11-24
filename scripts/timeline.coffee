# Description:
#   send all of the messages on Slack in #timeline
#
# Configuration:
#   create #timeline channel on your Slack team
#   SLACK_API_TOKEN                - Your Slack API token
#   SLACK_LINK_NAMES               - set 1 to enable link names in timeline
#   SLACK_TIMELINE_CHANNEL         - timeline channel name (defualt. timeline)
#   SLACK_TIMELINE_HUBOT_ID        - hubot ID in your Slack team
#   SLACK_TIMELINE_HUBOT_NAME      - hubot name
#   SLACK_TIMELINE_RANKING_ENABLED - set 1 to display ranking
#   SLACK_TIMELINE_RANKING_CHANNEL - ranking channel name (default. general)
#   SLACK_TIMELINE_RANKING_CRONJOB - ranking cron (default. "0 0 10 * * *")
#   TZ                             - set timezone
#
# Commands:
#   hubot ReloadMyImage
#
# Notes:
#   None
#
# Original Author:
#   vexus2
# Customized by:
#   knjcode

request = require 'request'
cloneDeep = require 'lodash.clonedeep'
cronJob = require('cron').CronJob

timezone = process.env.TZ ? ""

commands = ['setData', 'setLatestData', 'ReloadMyImage']

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
      enableReport()
    loaded = true

  sumUpMessagesPerChannel = (channel) ->
    if !data
      data = {}
    if !data[channel]
      data[channel] = 0
    data[channel]++

    # wait robot.brain.set until loaded avoid destruction of data
    if loaded
      robot.brain.data.timelineSumup = JSON.stringify data

  score = ->
    timeline_channel = process.env.SLACK_TIMELINE_CHANNEL ? "timeline"

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
      msgs = [ "いま話題のチャンネル(過去24時間の投稿数Top5 ##{timeline_channel} )" ]
      top5 = z[0..4]
      for msgsPerChannel in top5
        msgs.push("#"+msgsPerChannel[0]+" ("+msgsPerChannel[1]+"件)")
      return msgs.join("\n")
    return ""

  display_ranking = ->
    ranking_enabled = process.env.SLACK_TIMELINE_RANKING_ENABLED
    if ranking_enabled
      timeliner_id = process.env.SLACK_TIMELINE_HUBOT_ID
      timeliner_name = process.env.SLACK_TIMELINE_HUBOT_NAME
      link_names = process.env.SLACK_LINK_NAMES ? 0
      timeline_channel = process.env.SLACK_TIMELINE_RANKING_CHANNEL ? "general"
      timeliner_image = robot.brain.data.userImages[timeliner_id]
      ranking_text = encodeURIComponent(score())
      ranking_url = "https://slack.com/api/chat.postMessage?token=#{process.env.SLACK_API_TOKEN}&channel=%23#{timeline_channel}&text=#{ranking_text}&username=#{timeliner_name}&link_names=#{link_names}&pretty=1&icon_url=#{timeliner_image}"
      robot.logger.info ranking_url
      request ranking_url, (error, response, body) ->
        robot.logger.info(body)

  enableReport = ->
    ranking_enabled = process.env.SLACK_TIMELINE_RANKING_ENABLED
    if ranking_enabled
      for job in report
        job.stop()
      report = []

      ranking_cronjob = process.env.SLACK_TIMELINE_RANKING_CRONJOB ? "0 0 10 * * *"

      report[report.length] = new cronJob ranking_cronjob, () ->
        display_ranking()
      , null, true, timezone
      robot.logger.info("Set ranking cronjob at " + ranking_cronjob)

  # robot.respond /setData (.*)/, (msg) ->
  #   robot.brain.data.timelineSumup = msg.match[1]
  #   msg.send "set data"
  #   console.log robot.brain.data.timelineSumup

  # robot.respond /setLatestData (.*)/, (msg) ->
  #   robot.brain.data.timelineSumupLatest = msg.match[1]
  #   msg.send "set latestData"
  #   console.log robot.brain.data.timelineSumupLatest

  robot.respond /ReloadMyImage/, (msg) ->
    username = msg.message.user.name
    user_id = msg.message.user.id

    options =
      url: "https://slack.com/api/users.list?token=#{process.env.SLACK_API_TOKEN}&pretty=1"
      timeout: 2000
      headers: {}

    request options, (error, response, body) ->
      json = JSON.parse body
      i = 0
      try
        len = json.members.length
      catch error
        robot.logger.error("#{error}")
        len = 0

      while i < len
        if json.members[i].id is user_id
          image = json.members[i].profile.image_48
          robot.brain.data.userImages[user_id] = image
        ++i

    msg.send "Reload your Image."
    robot.logger.info("Reload #{username} Image")

  robot.hear /.*?/i, (msg) ->
    for command in commands
      if (msg.message.text.indexOf(command) isnt -1)
        return

    channel = msg.envelope.room
    message = msg.message.text
    username = msg.message.user.name
    user_id = msg.message.user.id

    # ignore DMs to hubot
    if channel is username
      return

    reloadUserImages(robot, user_id)
    user_image = robot.brain.data.userImages[user_id]
    if message.length > 0
      message = encodeURIComponent(message)
      link_names = process.env.SLACK_LINK_NAMES ? 0
      timeline_channel = process.env.SLACK_TIMELINE_CHANNEL ? "timeline"

      # ignore messages to timeline channel
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
      try
        len = json.members.length
      catch error
        robot.logger.error("#{error}")
        len = 0

      while i < len
        image = json.members[i].profile.image_48
        robot.brain.data.userImages[json.members[i].id] = image
        ++i
