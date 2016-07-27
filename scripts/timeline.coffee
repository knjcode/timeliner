# Description:
#   send all of the messages on Slack in #timeline
#
# Configuration:
#   create #timeline channel on your Slack team
#   SLACK_TIMELINE_MSG_REDIS       - set Redis URL for cache message timestamp
#   SLACK_LINK_NAMES               - set 1 to enable link names in timeline (default 1)
#   SLACK_UNFURL_LINKS             - set true to unfurl text-based content (default true)
#   SLACK_UNFURL_MEDIA             - set true to unfurl media content (default true)
#   SLACK_TIMELINE_CHANNEL         - timeline channel name (default. timeline)
#   SLACK_TIMELINE_RANKING_ENABLED - set true to display ranking (default false)
#   SLACK_TIMELINE_RANKING_CHANNEL - ranking channel name (default. general)
#   SLACK_TIMELINE_RANKING_CRONJOB - ranking cron (default. "0 0 9 * * *")
#   SLACK_TIMELINE_RANKING_TOP_N   - set number of members displayed in ranking (default. 5)
#   TZ                             - set timezone
#
# Commands:
#   None
#
# Notes:
#   None
#
# Original Author:
#   vexus2
# Customized by:
#   knjcode

{Promise} = require 'es6-promise'
cronJob = require('cron').CronJob
url = require 'url'
tsRedis = require 'redis'
timezone = process.env.TZ ? ""

timeline_channel = process.env.SLACK_TIMELINE_CHANNEL ? "timeline"
ranking_channel = process.env.SLACK_TIMELINE_RANKING_CHANNEL ? "general"
tsRedisUrl = process.env.SLACK_TIMELINE_MSG_REDIS ? 'redis://localhost:6379'
ranking_enabled = process.env.SLACK_TIMELINE_RANKING_ENABLED

link_names = process.env.SLACK_LINK_NAMES ? 1
unfurl_links = process.env.SLACK_UNFURL_LINKS ? true
unfurl_media = process.env.SLACK_UNFURL_MEDIA ? true
top_n = process.env.SLACK_TIMELINE_RANKING_TOP_N ? 5

info = url.parse tsRedisUrl, true
tsRedisClient = if info.auth then tsRedis.createClient(info.port, info.hostname, {no_ready_check: true}) else tsRedis.createClient(info.port, info.hostname)

module.exports = (robot) ->
  report = []

  prefix = robot.adapter.client.rtm.activeTeamId
  if info.auth
    tsRedisClient.auth info.auth.split(':')[1], (err) ->
      if err
        robot.logger.error "Failed to authenticate to timelineMessageRedis"
      else
        robot.logger.info "Successfully authenticated to timelineMessageRedis"

  tsRedisClient.on 'error', (err) ->
    if /ECONNREFUSED/.test then err.message else robot.logger.error err.stack

  tsRedisClient.on 'connect', ->
    robot.logger.debug "timeliner: Successfully connected to timelineMessageRedis"


  enableReport = ->
    if ranking_enabled
      for job in report
        job.stop()
      report = []
      ranking_cronjob = process.env.SLACK_TIMELINE_RANKING_CRONJOB ? "0 0 9 * * *"
      report[report.length] = new cronJob ranking_cronjob, () ->
        display_ranking()
      , null, true, timezone
      robot.logger.info("Set ranking cronjob at " + ranking_cronjob)
  enableReport()


  postMessage = (robot, channel_name, unformatted_text, user_name, icon_url) -> new Promise (resolve) ->
    robot.adapter.client.web.chat.postMessage channel_name, unformatted_text,
      link_names: link_names
      username: user_name
      unfurl_links: unfurl_links
      unfurl_media: unfurl_media
      icon_url: icon_url
    , (err, res) ->
      if err
        robot.logger.error err
      resolve res


  sumUpMessagesPerChannelId = (channelId) ->
    tsRedisClient.zincrby "#{prefix}:ranking", 1, "#{channelId}"


  score = -> new Promise (resolve) ->
    ranking = []
    tsRedisClient.zrevrange "#{prefix}:ranking", 0, top_n - 1, 'WITHSCORES', (err, reply) ->
      if err
        robot.logger.error "Failed to get ranking from timelineMessageRedis"
      else
        while reply.length isnt 0
          channelId = reply.shift()
          channelCount = reply.shift()
          channelName = robot.adapter.client.rtm.dataStore.getChannelGroupOrDMById(channelId).name
          ranking.push([channelName, channelCount])
        # display ranking
        if ranking.length > 0
          msgs = [ "いま話題のchannel (過去24時間の投稿数Top5 ##{timeline_channel})" ]
          for msgsPerChannel in ranking
            msgs.push("#"+msgsPerChannel[0]+" ("+msgsPerChannel[1]+"件)")
          resolve msgs.join("\n")
        resolve ""


  display_ranking = ->
    if ranking_enabled
      score()
      .then (ranking_text) ->
        if ranking_text.length > 0
          timeliner_image = robot.adapter.client.rtm.dataStore.users[robot.adapter.self.id].profile.image_48
          postMessage(robot, ranking_channel, ranking_text, robot.name, timeliner_image)
          .then (res) ->
            robot.logger.info "post ranking: #{JSON.stringify res}"
            tsRedisClient.del "#{prefix}:ranking"
        else
          robot.logger.info "no ranking data"


  removeFormatting = (text, mode) ->
    # https://api.slack.com/docs/message-formatting
    regex = ///
      <              # opening angle bracket
      ([@#!])?       # link type
      ([^>|]+)       # link
      (?:\|          # start of |label (optional)
      ([^>]+)        # label
      )?             # end of label
      >              # closing angle bracket
    ///g

    text = text.replace regex, (m, type, link, label) ->
      switch type

        when '@'
          if label then return label
          user = robot.adapter.client.rtm.dataStore.getUserById link
          if user
            return "@#{user.name}"

        when '#'
          if label then return label
          channel = robot.adapter.client.rtm.dataStore.getChannelGroupOrDMById link
          if channel
            return "\##{channel.name}"

        when '!'
          if link in ['channel','group','everyone','here']
            return "@#{link}"

        else
          if mode is 'label'
            return label if label
          link
    text = text.replace /&lt;/g, '<'
    text = text.replace /&gt;/g, '>'
    text = text.replace /&amp;/g, '&'


  # return link if no label
  removeFormattingLabel = (text) ->
    removeFormatting(text, 'label')


  removeFormattingLink = (text) ->
    removeFormatting(text, 'link')


  # copy messages in timeline_channel
  # robot.hear /.*?/i, (msg) ->
  #   # channel = msg.envelope.room
  #   channel = robot.adapter.client.rtm.dataStore.getChannelGroupOrDMById(msg.envelope.room).name
  #   robot.logger.info "\n#{msg.message.text}"
  #   message = removeFormatting msg.message.text
  #   username = msg.message.user.name
  #   userId = msg.message.user.id

  #   return if userId[0] is 'B' # ignore Bot message
  #   return if channel is 'DM' # ignore DMs to timeliner
  #   return if channel is timeline_channel # ignore timeline_channel messages

  #   originalTs = msg.envelope.message.id
  #   originalChannel = msg.envelope.message.room
  #   robot.logger.debug "originalTs: #{originalTs} originalChannel: #{originalChannel}"
  #   userImage = robot.adapter.client.rtm.dataStore.users[userId].profile.image_48
  #   if userImage is '' # set default userImage
  #     userImage = 'https://i0.wp.com/slack-assets2.s3-us-west-2.amazonaws.com/8390/img/avatars/ava_0002-48.png'
  #   if message.length > 0
  #     postMessage(robot, timeline_channel, "#{message} (##{channel})", username, userImage)
  #     .then (res) ->
  #       tsRedisClient.hsetnx "#{prefix}:#{originalChannel}", originalTs, res.ts
  #       sumUpMessagesPerChannelId(originalChannel)


  # change and delete timeline_channel messages
  targetChannelId = robot.adapter.client.rtm.dataStore.getChannelOrGroupByName(timeline_channel)?.id
  robot.adapter.client.rtm.on 'raw_message', (msg) ->
    msg = JSON.parse(msg)

    # bot_message
    if msg.type is 'message' and msg.subtype is 'bot_message'
      return # ignore bot message

    # copy messages
    if msg.type is 'message' and ((msg.subtype is undefined) or (msg.subtype is 'file_share'))
      return if msg.channel is targetChannelId # return if timeline_channel messages changed
      return if msg.channel[0] is 'D' # ignore DMs to timeliner

      message = ''
      if msg.subtype is undefined # normal message
        message = removeFormattingLabel msg.text
      if msg.subtype is 'file_share' # file share
        message = removeFormattingLink msg.text

      message_channel = robot.adapter.client.rtm.dataStore.getChannelGroupOrDMById(msg.channel).name

      username = robot.adapter.client.rtm.dataStore.getUserById(msg.user).name
      originalTs = msg.ts
      originalChannel = msg.channel
      robot.logger.debug "originalTs: #{originalTs} originalChannel: #{originalChannel}"
      userImage = robot.adapter.client.rtm.dataStore.users[msg.user].profile.image_48
      if userImage is '' # set default userImage
        userImage = 'https://i0.wp.com/slack-assets2.s3-us-west-2.amazonaws.com/8390/img/avatars/ava_0002-48.png'
      if message.length > 0
        postMessage(robot, timeline_channel, "#{message} (##{message_channel})", username, userImage)
        .then (res) ->
          tsRedisClient.hsetnx "#{prefix}:#{originalChannel}", originalTs, res.ts
          sumUpMessagesPerChannelId(originalChannel)

    # change messages
    if msg.type is 'message' and msg.subtype is 'message_changed'
      return if msg.channel is targetChannelId # return if timeline_channel messages changed
      return if msg.message.text is msg.previous_message.text # return if text not changed
      message_channel = robot.adapter.client.rtm.dataStore.getChannelGroupOrDMById(msg.channel).name

      message = removeFormattingLabel msg.message.text
      text = "#{message} (##{message_channel})"

      tsRedisClient.hget "#{prefix}:#{msg.channel}", msg.previous_message.ts, (err, reply) ->
        if err
          robot.logger.error err
        else
          robot.adapter.client.web.chat.update reply, targetChannelId, text,
            parse: 'full',
            link_names: link_names
          , (err, res) ->
            if err
              robot.logger.error err
            else
              robot.logger.debug "change timeline message #{JSON.stringify res}"

    # delete messages
    if msg.type is 'message' and msg.subtype is 'message_deleted'
      return if msg.channel is targetChannelId # return if timeline_channel messages deleted
      tsRedisClient.hget "#{prefix}:#{msg.channel}", msg.previous_message.ts, (err, reply) ->
        robot.adapter.client.web.chat.delete reply, targetChannelId, (err, res) ->
          if err
            robot.logger.error err
          else
            robot.logger.debug "delete timeline message #{JSON.stringify res}"
