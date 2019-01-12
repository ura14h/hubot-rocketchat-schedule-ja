# Description:
#   Schedule a message in both cron-style and datetime-based format pattern
#
# Dependencies:
#   "node-schedule" : "~1.0.0",
#   "cron-parser"   : "~1.0.1"
#
# Commands:
#   hubot schedule `<cron pattern>` <message> - Schedule a message that runs recurrently.
#   hubot schedule `<datetime pattern>` <message> - Schedule a message that runs on a specific date and time.
#   hubot schedule cancel <id> - Cancel the schedule specified by <id>.
#   hubot schedule update <id> <message> - Update the message of schedule  specified by <id>.
#   hubot schedule list - List all schedules for the current room.
#   hubot schedule statistics - Show statistics about scheduled messages.
#   hubot schedule example - Show command examples.
#
# Author:
#   matsukaz <matsukaz@gmail.com>
#   ura14h <ishiura@ja2.so-net.ne.jp>

scheduler = require('node-schedule')
cronParser = require('cron-parser')
{TextMessage} = require('hubot')
JOBS = {}
JOB_MAX_COUNT = 10000
STORE_KEY = 'hubot_rochetchat_schedule'

module.exports = (robot) ->
  robot.brain.on 'loaded', =>
    syncSchedules robot

  if !robot.brain.get(STORE_KEY)
    robot.brain.set(STORE_KEY, {})

  robot.respond /schedule `(.*?)` ((?:.|\s)*)$/i, (msg) ->
    schedule robot, msg, msg.match[1], msg.match[2]

  robot.respond /schedule cancel (\d+)$/i, (msg) ->
    cancelSchedule robot, msg, msg.match[1]

  robot.respond /schedule update (\d+) ((?:.|\s)*)$/i, (msg) ->
    updateSchedule robot, msg, msg.match[1], msg.match[2]

  robot.respond /schedule list$/i, (msg) ->
    # split jobs into date and cron pattern jobs
    room = getRoom(robot, msg)
    dateJobs = {}
    cronJobs = {}
    for id, job of JOBS
      if job.room.id == room.id
        if job.pattern instanceof Date
          dateJobs[id] = job
        else
          cronJobs[id] = job

    # sort by date in ascending order
    text = ''
    for id in (Object.keys(dateJobs).sort (a, b) -> new Date(dateJobs[a].pattern) - new Date(dateJobs[b].pattern))
      job = dateJobs[id]
      text += "> #{id} - `#{formatDate(new Date(job.pattern))}` #{job.message} \n"
    for id, job of cronJobs
      text += "> #{id} - `#{job.pattern}` #{job.message} \n"

    if !!text.length
      count = Object.keys(dateJobs).length + Object.keys(cronJobs).length
      msg.send """
        スケジュールされたメッセージが #{count} 件あります:
        #{text}
      """
    else
      msg.send 'スケジュールされたメッセージはありません'

  robot.respond /schedule statistics$/i, (msg) ->
    messageAllCount = 0
    messageDatetimeCount = 0
    messageCronCount = 0
    publicRooms = {}
    privateGroups = {}
    directMessages = {}
    otherRooms = {}
    for id, job of JOBS
      messageAllCount++
      if job.pattern instanceof Date
        messageDatetimeCount++
      else
        messageCronCount++
      switch job.room.type
        when 'c'
          if !publicRooms[job.room.id]
            publicRooms[job.room.id] = job.room
        when 'p'
          if !privateGroups[job.room.id]
            privateGroups[job.room.id] = job.room
        when 'd'
          if !directMessages[job.room.id]
            directMessages[job.room.id] = job.room
        else
          if !otherRooms[job.room.id]
            otherRooms[job.room.id] = job.room
    publicRoomCount = Object.keys(publicRooms).length || 0
    privateGroupCount = Object.keys(privateGroups).length || 0
    directMessageCount = Object.keys(directMessages).length || 0
    otherRoomCount = Object.keys(otherRooms).length || 0
    roomCount = publicRoomCount + privateGroupCount + directMessageCount + otherRoomCount

    msg.send """
      システム全体のスケジュールの統計です:
      > スケジュールの合計: #{messageAllCount} 件
      > - クロンパターン指定 #{messageCronCount} 件
      > - 日時パターン指定 #{messageDatetimeCount} 件
      > ルームの合計: #{roomCount} 件
      > - チャンネル向け #{publicRoomCount} 件
      > - プライベートグループ向け #{privateGroupCount} 件
      > - ダイレクトメッセージ向け #{directMessageCount} 件
    """

  robot.respond /schedule example$/i, (msg) ->
    command = robot.name + ' schedule'
    room = getRoom(robot, msg)
    if room.type == 'd'
      command = 'schedule'
    
    msg.send """
      メッセージをスケジュールするコマンドの例です:
      ```
      #{command} `2019-01-01 01:00` 2019年1月1日の午前1時に、このメッセージをつぶやきます
      #{command} `0 9 * * *` 毎日の9時0分に、このメッセージをつぶやきます
      #{command} `30 17 * * 4` 毎週木曜日の17時30分に、このメッセージをつぶやきます
      #{command} `0 9 1 * *` 毎月1日の9時0分に、このメッセージをつぶやきます
      #{command} `0 10,15 * * *` 毎日の10時0分と15時0分に、このメッセージをつぶやきます
      #{command} `30 20 * * 1-5` 月曜日から金曜日までの20時30分に、このメッセージをつぶやきます
      ```
    """


schedule = (robot, msg, pattern, message) ->
  if JOB_MAX_COUNT <= Object.keys(JOBS).length
    return msg.send 'スケジュールされたメッセージが多すぎます'

  id = Math.floor(Math.random() * JOB_MAX_COUNT) while !id? || JOBS[id]
  user = getUser(robot, msg)
  room = getRoom(robot, msg)
  try
    job = createSchedule robot, id, pattern, user, room, message
    if job
      msg.send "スケジュール #{id} が作成されました"
    else
      msg.send "\"#{pattern}\" は無効なパターンです。"
  catch error
    return msg.send error.message


createSchedule = (robot, id, pattern, user, room, message) ->
  if isCronPattern(pattern)
    return createCronSchedule robot, id, pattern, user, room, message

  date = Date.parse(pattern)
  if !isNaN(date)
    if date < Date.now()
      throw new Error "\"#{pattern}\" はすでに過去の日時です"
    return createDatetimeSchedule robot, id, pattern, user, room, message


createCronSchedule = (robot, id, pattern, user, room, message) ->
  startSchedule robot, id, pattern, user, room, message


createDatetimeSchedule = (robot, id, pattern, user, room, message) ->
  startSchedule robot, id, new Date(pattern), user, room, message, () ->
    delete JOBS[id]
    delete robot.brain.get(STORE_KEY)[id]


startSchedule = (robot, id, pattern, user, room, message, cb) ->
  job = new Job(id, pattern, user, room, message, cb)
  job.start(robot)
  JOBS[id] = job
  robot.brain.get(STORE_KEY)[id] = job.serialize()


updateSchedule = (robot, msg, id, message) ->
  job = JOBS[id]
  if !job
    return msg.send "スケジュール #{id} が見つかりません"
  room = getRoom(robot, msg)
  if job.room != room
    return msg.send "スケジュール #{id} が見つかりません"

  job.message = message
  robot.brain.get(STORE_KEY)[id] = job.serialize()
  msg.send "スケジュール #{id} のメッセージを更新しました"


cancelSchedule = (robot, msg, id) ->
  job = JOBS[id]
  if !job
    return msg.send "スケジュール #{id} が見つかりません"
  room = getRoom(robot, msg)
  if job.room != room
    return msg.send "スケジュール #{id} が見つかりません"

  job.cancel()
  delete JOBS[id]
  delete robot.brain.get(STORE_KEY)[id]
  msg.send "スケジュール #{id} は取り消されました"


syncSchedules = (robot) ->
  if !robot.brain.get(STORE_KEY)
    robot.brain.set(STORE_KEY, {})

  nonCachedSchedules = difference(robot.brain.get(STORE_KEY), JOBS)
  for own id, job of nonCachedSchedules
    scheduleFromBrain robot, id, job...

  nonStoredSchedules = difference(JOBS, robot.brain.get(STORE_KEY))
  for own id, job of nonStoredSchedules
    storeScheduleInBrain robot, id, job


scheduleFromBrain = (robot, id, pattern, user, room, message) ->
  try
    createSchedule robot, id, pattern, user, room, message
  catch error
    return delete robot.brain.get(STORE_KEY)[id]


storeScheduleInBrain = (robot, id, job) ->
  robot.brain.get(STORE_KEY)[id] = job.serialize()


difference = (obj1 = {}, obj2 = {}) ->
  diff = {}
  for id, job of obj1
    diff[id] = job if id !of obj2
  return diff


isCronPattern = (pattern) ->
  errors = cronParser.parseString(pattern).errors
  return !Object.keys(errors).length


getUser = (robot, msg) ->
  user = { id: msg.message.user.id, name: msg.message.user.name }
  return user


getRoom = (robot, msg) ->
  room = { id: msg.message.user.roomID, type: msg.message.user.roomType, name: msg.message.user.room }
  return room


toTwoDigits = (num) ->
  ('0' + num).slice(-2)


formatDate = (date) ->
  offset = -date.getTimezoneOffset();
  sign = ' GMT+'
  if offset < 0
    offset = -offset
    sign = ' GMT-'
  [date.getFullYear(), toTwoDigits(date.getMonth()+1), toTwoDigits(date.getDate())].join('-') + ' ' + date.toLocaleTimeString() + sign + toTwoDigits(offset / 60) + ':' + toTwoDigits(offset % 60);


class Job
  constructor: (id, pattern, user, room, message, cb) ->
    @id = id
    @pattern = pattern
    @user = user
    @room = room
    @message = message
    @cb = cb
    @job

  start: (robot) ->
    @job = scheduler.scheduleJob(@pattern, =>
      executeJob robot, @id, @user, @room, @message, @cb
    )

  cancel: ->
    scheduler.cancelJob @job if @job
    @cb?()

  serialize: ->
    [@pattern, @user, @room, @message]

executeJob =  (robot, id, user, room, message, cb) ->
  robot.adapter.driver.asyncCall 'getRoomNameById', room.id
  .then (result) ->
    envelope = room: room.id
    robot.send envelope, message
    cb?()
  .catch (error) ->
    if error.error == 'error-not-allowed'
      job = JOBS[id]
      job.cancel()
      delete JOBS[id]
      delete robot.brain.get(STORE_KEY)[id]
      robot.logger.warning "#{id}: The schedule has been canceled because robot can not access the room."
