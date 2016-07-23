# Description:
#   send all of the messages on Slack in #timeline
#
# Configuration:
#   create #timeline channel on your Slack team
#   SLACK_TIMELINE_MSG_REDIS       - set message ts caching Redis URL
#   SLACK_TIMELINE_TEAM_NAME       - set prefix of message caching Redis
#   SLACK_LINK_NAMES               - set 1 to enable link names in timeline
#   SLACK_UNFURL_LINKS             - set true to unfurl text-based content
#   SLACK_UNFURL_MEDIA             - set true to unfurl media content
#   SLACK_TIMELINE_CHANNEL         - timeline channel name (defualt. timeline)
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
url = require 'url'
tsRedis = require 'redis'

timezone = process.env.TZ ? ""

commands = ['setData', 'setLatestData', 'ReloadMyImage']

module.exports = (robot) ->

  data = {}
  latestData = {}
  report = []
  loaded = false

  info = url.parse process.env.SLACK_TIMELINE_MSG_REDIS
  tsRedisClient = if info.auth then tsRedis.createClient(info.port, info.hostname, {no_ready_check: true}) else tsRedis.createClient(info.port, info.hostname)
  prefix = process.env.SLACK_TIMELINE_TEAM_NAME

  if info.auth
    tsRedisClient.auth info.auth, (err) ->
      if err
        robot.logger.error "timeliner: Failed to authenticate to timelineMessageRedis"
      else
        robot.logger.info "timeliner: Successfully authenticated to timelineMessageRedis"

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
    # sort diff by value
    z = []
    for key,value of diff
      z.push([key,value])
    z.sort( (a,b) -> b[1] - a[1] )
    # display ranking
    if z.length > 0
      msgs = [ "いま話題のchannel (過去24時間の投稿数Top5 ##{timeline_channel})" ]
      top5 = z[0..4]
      for msgsPerChannel in top5
        msgs.push("#"+msgsPerChannel[0]+" ("+msgsPerChannel[1]+"件)")
      return msgs.join("\n")
    return ""


  display_ranking = ->
    ranking_enabled = process.env.SLACK_TIMELINE_RANKING_ENABLED
    if ranking_enabled
      timeliner_name = robot.adapter.self.name
      link_names = process.env.SLACK_LINK_NAMES ? 0
      ranking_channel = process.env.SLACK_TIMELINE_RANKING_CHANNEL ? "general"
      timeliner_image = robot.brain.data.userImages[robot.adapter.self.id]
      ranking_text = score()
      if ranking_text.length > 0
        robot.adapter.client._apiCall 'chat.postMessage',
          channel: ranking_channel
          text: ranking_text
          username: timeliner_name
          link_names: link_names
          icon_url: timeliner_image
        , (res) ->
          robot.logger.info "post ranking: #{JSON.stringify res}"
          # update latestData
          latestData = cloneDeep data
          robot.brain.data.timelineSumupLatest = JSON.stringify latestData


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


  robot.respond /ReloadMyImage/, (msg) ->
    username = msg.message.user.name
    userId = msg.message.user.id
    reloadUserImages(robot, userId, true)
    msg.send "Reload your Image."


  # copy messages in timeline_channel
  robot.hear /.*?/i, (msg) ->
    for command in commands
      if (msg.message.text.indexOf(command) isnt -1)
        return
    channel = msg.envelope.room
    message = msg.message.text
    username = msg.message.user.name
    userId = msg.message.user.id
    # ignore DMs to hubot
    if channel is username
      return

    originalTs = msg.envelope.message.rawMessage.ts
    originalChannel = msg.envelope.message.rawMessage.channel
    robot.logger.debug "originalTs: #{originalTs} originalChannel: #{originalChannel}"

    reloadUserImages(robot, userId)
    userImage = robot.brain.data.userImages[userId]
    if message.length > 0
      link_names = process.env.SLACK_LINK_NAMES ? 0
      unfurl_links = process.env.SLACK_UNFURL_LINKS ? false
      unfurl_media = process.env.SLACK_UNFURL_MEDIA ? false
      timeline_channel = process.env.SLACK_TIMELINE_CHANNEL ? "timeline"
      # ignore messages to timeline channel
      if channel is timeline_channel
        return

      if userImage is ''
        userImage = 'https://i0.wp.com/slack-assets2.s3-us-west-2.amazonaws.com/8390/img/avatars/ava_0002-48.png'

      robot.adapter.client._apiCall 'chat.postMessage',
        channel: timeline_channel
        text: "#{message} (##{channel})"
        username: username
        link_names: link_names
        unfurl_links: unfurl_links
        unfurl_media: unfurl_media
        icon_url: userImage
      , (res) ->
        tsRedisClient.hsetnx "#{prefix}:#{originalChannel}", originalTs, res.ts

      sumUpMessagesPerChannel(channel)


  # change and delete timeline_channel messages
  robot.adapter.client.on 'raw_message', (msg) ->
    timeline_channel = process.env.SLACK_TIMELINE_CHANNEL ? "timeline"
    targetChannelId = robot.adapter.client.getChannelGroupOrDMByName(timeline_channel)?.id

    # change messages
    if msg.type is 'message' and msg.subtype is 'message_changed'
      return if msg.channel is targetChannelId # return if timeline_channel messages changed
      return if msg.message.text is msg.previous_message.text # return if text not changed
      link_names = process.env.SLACK_LINK_NAMES ? 0
      message_channel = robot.adapter.client.getChannelGroupOrDMByID(msg.channel).name

      message = robot.adapter.removeFormatting msg.message.text
      tsRedisClient.hget "#{prefix}:#{msg.channel}", msg.previous_message.ts, (err, reply) ->
        robot.adapter.client._apiCall 'chat.update',
          ts: reply
          channel: targetChannelId
          text: "#{message} (##{message_channel})"
          parse: 'full'
          link_names: link_names
        , (res) ->
          robot.logger.debug "change timeline message #{JSON.stringify res}"

    # delete messages
    if msg.type is 'message' and msg.subtype is 'message_deleted'
      return if msg.channel is targetChannelId # return if timeline_channel messages deleted
      tsRedisClient.hget "#{prefix}:#{msg.channel}", msg.previous_message.ts, (err, reply) ->
        robot.adapter.client._apiCall 'chat.delete',
          ts: reply
          channel: targetChannelId
        , (res) ->
          robot.logger.debug "delete timeline message #{JSON.stringify res}"

    # change user
    if msg.type is 'user_change'
      userId = msg.user.id
      reloadUserImages(robot, userId, true)
      robot.logger.debug 'auto update user image'


  reloadUserImages = (robot, userId, justOne) ->
    robot.brain.data.userImages = {} if !robot.brain.data.userImages
    robot.brain.data.userImages[userId] = '' if !robot.brain.data.userImages[userId]?
    unless justOne
      return if robot.brain.data.userImages[userId] isnt ''
    username = robot.adapter.client.getUserByID(userId).name
    robot.adapter.client._apiCall 'users.list', {}, (res) ->
      for i in [0...res.members.length]
        targetId = res.members[i].id
        targetImage = res.members[i].profile.image_48
        if justOne
          if targetId is userId
            robot.logger.info "Reload #{username} image. targetId: #{targetId} targetImage: #{targetImage}"
            robot.brain.data.userImages[userId] = targetImage
        else
          robot.brain.data.userImages[targetId] = targetImage
