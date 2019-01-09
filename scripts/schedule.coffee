# Description:
#   Schedule a message in both cron-style and datetime-based format pattern
#
# Dependencies:
#   "node-schedule" : "~1.0.0",
#   "cron-parser"   : "~1.0.1"
#
# Configuration:
#   HUBOT_SCHEDULE_DEBUG - set "1" for debug
#   HUBOT_SCHEDULE_DONT_RECEIVE - set "1" if you don't want hubot to be processed by scheduled message
#   HUBOT_SCHEDULE_DENY_EXTERNAL_CONTROL - set "1" if you want to deny scheduling from other rooms
#   HUBOT_SCHEDULE_LIST_REPLACE_TEXT - set JSON object like '{"@":"[at]"}' to configure text replacement used when listing scheduled messages
#
# Commands:
#   hubot schedule add "<datetime pattern>" <message> - Schedule a message that runs on a specific date and time
#   hubot schedule add "<cron pattern>" <message> - Schedule a message that runs recurrently
#   hubot schedule add #<room> "<datetime pattern>" <message> - Schedule a message to a specific room that runs on a specific date and time
#   hubot schedule add #<room> "<cron pattern>" <message> - Schedule a message to a specific room that runs recurrently
#   hubot schedule cancel <id> - Cancel the schedule
#   hubot schedule update <id> <message> - Update scheduled message
#   hubot schedule list - List all scheduled messages for current room
#   hubot schedule list #<room> - List all scheduled messages for specified room
#   hubot schedule list all - List all scheduled messages for any rooms
#
# Author:
#   matsukaz <matsukaz@gmail.com>
#   ura14h <ishiura@ja2.so-net.ne.jp>

# configuration settings
config =
  debug: process.env.HUBOT_SCHEDULE_DEBUG
  dont_receive: process.env.HUBOT_SCHEDULE_DONT_RECEIVE
  deny_external_control: process.env.HUBOT_SCHEDULE_DENY_EXTERNAL_CONTROL
  list:
    replace_text: JSON.parse(process.env.HUBOT_SCHEDULE_LIST_REPLACE_TEXT ? '{"@":"[@]"}')

scheduler = require('node-schedule')
cronParser = require('cron-parser')
{TextMessage} = require('hubot')
JOBS = {}
JOB_MAX_COUNT = 10000
STORE_KEY = 'hubot_schedule'

module.exports = (robot) ->
  robot.brain.on 'loaded', =>
    syncSchedules robot

  if !robot.brain.get(STORE_KEY)
    robot.brain.set(STORE_KEY, {})

  robot.respond /schedule help$/i, (msg) ->
    prefix = msg.robot.name + ' '
    if msg.envelope.user.roomType == 'd'
      prefix = ''
    text = """
      ボットスケジュールコマンドは次のとおりです:
      > #{prefix}schedule help -- このヘルプ
      > #{prefix}schedule help cron -- クロン形式のヘルプ
      > #{prefix}schedule help datetime -- 日時形式のヘルプ
      > #{prefix}schedule add "<日時形式>" <メッセージ> -- 特定の日時に実行されるメッセージをスケジュールする
      > #{prefix}schedule add "<クロン形式>" <メッセージ> -- 繰り返し実行されるメッセージをスケジュールする
    """
    if config.deny_external_control isnt '1'
      text += "\n"
      text += """
        > #{prefix}schedule add #<ルーム> "<日時形式>" <メッセージ> -- 特定の日時に実行される特定のルームにメッセージをスケジュールする
        > #{prefix}schedule add #<ルーム> "<クロン形式>" <メッセージ> -- 繰り返し実行される特定のルームにメッセージをスケジュールする
      """
    text += "\n"
    text += """
      > #{prefix}schedule cancel <id> -- スケジュールを取り消す
      > #{prefix}schedule update <id> <メッセージ> -- スケジュールされたメッセージを更新する
      > #{prefix}schedule list -- 現在のルームでスケジュールされているすべてのメッセージを一覧表示
    """
    if config.deny_external_control isnt '1'
      text += "\n"
      text += """
        > #{prefix}schedule list #<ルーム> -- 指定されたルームでスケジュールされているすべてのメッセージを一覧表示
        > #{prefix}schedule list all -- すべてのスケジュールされたメッセージを一覧表示
      """
    msg.send text

  robot.respond /schedule help cron$/i, (msg) ->
    msg.send """
      クロン形式の書式は次の通りです:
      > "分 時 日 月 曜日"
      書式の各項目は次の通りです:
      > 分 -- 0〜59
      > 時 -- 0〜23
      > 日 -- 1〜31
      > 月 -- 1〜12
      > 曜日 -- 0〜7 (0 と 7 が日曜日)
      数値の代わりにアスタリスク記号(`*`)を指定した場合は毎分、毎時、毎日、毎月などの意味になります。
      単純な数値の代わりにカンマ区切りでリスト指定やハイフン区切りで範囲指定することもできます。
      詳細な書式は http://crontab.org/ を参照してください。
    """

  robot.respond /schedule help datetime$/i, (msg) ->
    msg.send """
      日時形式の書式は次の通りです:
      > "YYYY-MM-DD hh:mm"
      書式の各項目は次の通りです:
      > YYYY -- 4 桁の年
      > MM -- 2 桁の月 (必要に応じて先頭に 0 を付加)
      > DD -- 2 桁の日付 (必要に応じて先頭に 0 を付加)
      > hh -- 2 桁の時
      > mm -- 2 桁の分
    """


  robot.respond /schedule add(?: #(.*))? "(.*?)" ((?:.|\s)*)$/i, (msg) ->
    target_room = msg.match[1]

    if not is_blank(target_room) and isRestrictedRoom(target_room, robot, msg)
      return msg.send "他のルームのスケジュール作成は制限されています"
    schedule robot, msg, target_room, msg.match[2], msg.match[3]


  robot.respond /schedule list(?: (all|#.*))?/i, (msg) ->
    target_room = msg.match[1]
    room_id = msg.message.user.room
    room_name = getRoomName(robot, msg.message.user)
    if is_blank(target_room) or config.deny_external_control is '1'
      # if target_room is undefined or blank, show schedule for current room
      # room is ignored when HUBOT_SCHEDULE_DENY_EXTERNAL_CONTROL is set to 1
      rooms = [room_name, msg.message.user.reply_to]
    else if target_room == "all"
      show_all = true
    else
      rooms = [target_room[1..]]

    # split jobs into date and cron pattern jobs
    dateJobs = {}
    cronJobs = {}
    for id, job of JOBS

      # backward compatibility
      # hubot-schedule under v0.5.1 holds it's job by room_id instead of room_name
      if job.user.room == room_id
        job.user.room = room_name

      if show_all or job.user.room in rooms
        if job.pattern instanceof Date
          dateJobs[id] = job
        else
          cronJobs[id] = job

    # sort by date in ascending order
    text = ''
    for id in (Object.keys(dateJobs).sort (a, b) -> new Date(dateJobs[a].pattern) - new Date(dateJobs[b].pattern))
      job = dateJobs[id]
      text += "#{id}: [ #{formatDate(new Date(job.pattern))} ] \##{job.user.room} #{job.message} \n"

    for id, job of cronJobs
      text += "#{id}: [ #{job.pattern} ] \##{job.user.room} #{job.message} \n"

    if !!text.length
      text = text.replace(///#{org_text}///g, replaced_text) for org_text, replaced_text of config.list.replace_text
      msg.send text
    else
      msg.send 'メッセージはスケジュールされていません'

  robot.respond /schedule update (\d+) ((?:.|\s)*)/i, (msg) ->
    updateSchedule robot, msg, msg.match[1], msg.match[2]

  robot.respond /schedule cancel (\d+)/i, (msg) ->
    cancelSchedule robot, msg, msg.match[1]


schedule = (robot, msg, room, pattern, message) ->
  if JOB_MAX_COUNT <= Object.keys(JOBS).length
    return msg.send "スケジュールされたメッセージが多すぎます"

  id = Math.floor(Math.random() * JOB_MAX_COUNT) while !id? || JOBS[id]
  try
    job = createSchedule robot, id, pattern, msg.message.user, room, message
    if job
      msg.send "#{id}: スケジュールが作成されました"
    else
      prefix = msg.robot.name + ' '
      if msg.envelope.user.roomType == 'd'
        prefix = ''
      msg.send """
        \"#{pattern}\" は無効なパターンです。
        指定できるパターンは次のヘルプで確認できます:
        > #{prefix}schedule help cron -- クロン形式のヘルプ
        > #{prefix}schedule help datetime -- 日時形式のヘルプ
      """
  catch error
    return msg.send error.message


createSchedule = (robot, id, pattern, user, room, message) ->
  if isCronPattern(pattern)
    return createCronSchedule robot, id, pattern, user, room, message

  date = Date.parse(pattern)
  if !isNaN(date)
    if date < Date.now()
      throw new Error "\"#{pattern}\" はすでに過去です"
    return createDatetimeSchedule robot, id, pattern, user, room, message


createCronSchedule = (robot, id, pattern, user, room, message) ->
  startSchedule robot, id, pattern, user, room, message


createDatetimeSchedule = (robot, id, pattern, user, room, message) ->
  startSchedule robot, id, new Date(pattern), user, room, message, () ->
    delete JOBS[id]
    delete robot.brain.get(STORE_KEY)[id]


startSchedule = (robot, id, pattern, user, room, message, cb) ->
  if !room
    room = getRoomName(robot, user)
  job = new Job(id, pattern, user, room, message, cb)
  job.start(robot)
  JOBS[id] = job
  robot.brain.get(STORE_KEY)[id] = job.serialize()


updateSchedule = (robot, msg, id, message) ->
  job = JOBS[id]
  return msg.send "スケジュール #{id} は見つかりません" if !job

  if isRestrictedRoom(job.user.room, robot, msg)
    return msg.send "他のルームのスケジュール更新は制限されています"

  job.message = message
  robot.brain.get(STORE_KEY)[id] = job.serialize()
  msg.send "#{id}: スケジュールされたメッセージを更新しました"


cancelSchedule = (robot, msg, id) ->
  job = JOBS[id]
  return msg.send "#{id}: スケジュールが見つかりません" if !job

  if isRestrictedRoom(job.user.room, robot, msg)
    return msg.send "他のルームのスケジュール取り消しは制限されています"

  job.cancel()
  delete JOBS[id]
  delete robot.brain.get(STORE_KEY)[id]
  msg.send "#{id}: スケジュールは取り消されました"


syncSchedules = (robot) ->
  if !robot.brain.get(STORE_KEY)
    robot.brain.set(STORE_KEY, {})

  nonCachedSchedules = difference(robot.brain.get(STORE_KEY), JOBS)
  for own id, job of nonCachedSchedules
    scheduleFromBrain robot, id, job...

  nonStoredSchedules = difference(JOBS, robot.brain.get(STORE_KEY))
  for own id, job of nonStoredSchedules
    storeScheduleInBrain robot, id, job


scheduleFromBrain = (robot, id, pattern, user, message) ->
  envelope = user: user, room: user.room
  try
    createSchedule robot, id, pattern, user, user.room, message
  catch error
    robot.send envelope, "#{id}: データベースから再スケジュールできませんでした. [#{error.message}]" if config.debug is '1'
    return delete robot.brain.get(STORE_KEY)[id]

  robot.send envelope, "#{id} データベースから再スケジュールしました" if config.debug is '1'


storeScheduleInBrain = (robot, id, job) ->
  robot.brain.get(STORE_KEY)[id] = job.serialize()

  envelope = user: job.user, room: job.user.room
  robot.send envelope, "#{id}: スケジュールはデータベースに非同期的に保存されます" if config.debug is '1'


difference = (obj1 = {}, obj2 = {}) ->
  diff = {}
  for id, job of obj1
    diff[id] = job if id !of obj2
  return diff


isCronPattern = (pattern) ->
  errors = cronParser.parseString(pattern).errors
  return !Object.keys(errors).length


is_blank = (s) -> !s?.trim()


is_empty = (o) -> Object.keys(o).length == 0


isRestrictedRoom = (target_room, robot, msg) ->
  if config.deny_external_control is '1'
    if target_room not in [getRoomName(robot, msg.message.user), msg.message.user.reply_to]
      return true
  return false


toTwoDigits = (num) ->
  ('0' + num).slice(-2)


formatDate = (date) ->
  offset = -date.getTimezoneOffset();
  sign = ' GMT+'
  if offset < 0
    offset = -offset
    sign = ' GMT-'
  [date.getFullYear(), toTwoDigits(date.getMonth()+1), toTwoDigits(date.getDate())].join('-') + ' ' + date.toLocaleTimeString() + sign + toTwoDigits(offset / 60) + ':' + toTwoDigits(offset % 60);


getRoomName = (robot, user) ->
  try
    # Slack adapter needs to convert from room identifier
    # https://slackapi.github.io/hubot-slack/upgrading
    return robot.adapter.client.rtm.dataStore.getChannelGroupOrDMById(user.room).name
  catch e
    return user.room


class Job
  constructor: (id, pattern, user, room, message, cb) ->
    @id = id
    @pattern = pattern
    @user = { room: (room || user.room) }
    @user[k] = v for k,v of user when k in ['id','team_id','name'] # copy only needed properties
    @message = message
    @cb = cb
    @job

  start: (robot) ->
    @job = scheduler.scheduleJob(@pattern, =>
      envelope = user: @user, room: @user.room
      robot.send envelope, @message
      robot.adapter.receive new TextMessage(@user, @message) unless config.dont_receive is '1'
      @cb?()
    )

  cancel: ->
    scheduler.cancelJob @job if @job
    @cb?()

  serialize: ->
    [@pattern, @user, @message]
