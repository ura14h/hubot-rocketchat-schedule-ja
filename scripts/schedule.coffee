# Description:
#   Schedule a message in both cron-style and datetime-based format pattern
#
# Dependencies:
#   "node-schedule" : "~1.0.0",
#   "cron-parser"   : "~1.0.1"
#
# Commands:
#   hubot schedule add "<datetime pattern>" <message> - Schedule a message that runs on a specific date and time
#   hubot schedule add "<cron pattern>" <message> - Schedule a message that runs recurrently
#   hubot schedule cancel <id> - Cancel the schedule
#   hubot schedule update <id> <message> - Update scheduled message
#   hubot schedule list - List all scheduled messages for current room
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

  robot.respond /schedule add "(.*?)" ((?:.|\s)*)$/i, (msg) ->
    schedule robot, msg, null, msg.match[1], msg.match[2]

  robot.respond /schedule list/i, (msg) ->
    # split jobs into date and cron pattern jobs
    dateJobs = {}
    cronJobs = {}
    for id, job of JOBS
      if !isOtherRoom(job.room, robot, msg)
        if job.pattern instanceof Date
          dateJobs[id] = job
        else
          cronJobs[id] = job

    # sort by date in ascending order
    text = ''
    for id in (Object.keys(dateJobs).sort (a, b) -> new Date(dateJobs[a].pattern) - new Date(dateJobs[b].pattern))
      job = dateJobs[id]
      text += "#{id}: [ #{formatDate(new Date(job.pattern))} ] #{job.message} \n"
    for id, job of cronJobs
      text += "#{id}: [ #{job.pattern} ] #{job.message} \n"

    if !!text.length
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
      msg.send "\"#{pattern}\" は無効なパターンです。"
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
    room = user.room
  job = new Job(id, pattern, user, room, message, cb)
  job.start(robot)
  JOBS[id] = job
  robot.brain.get(STORE_KEY)[id] = job.serialize()


updateSchedule = (robot, msg, id, message) ->
  job = JOBS[id]
  if !job || isOtherRoom(job.room, robot, msg)
    return msg.send "スケジュール #{id} は見つかりません"
  job.message = message
  robot.brain.get(STORE_KEY)[id] = job.serialize()
  msg.send "#{id}: スケジュールされたメッセージを更新しました"


cancelSchedule = (robot, msg, id) ->
  job = JOBS[id]
  if !job || isOtherRoom(job.room, robot, msg)
    return msg.send "スケジュール #{id} は見つかりません"
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


isOtherRoom = (room, robot, msg) ->
  if room not in [msg.message.user.room, msg.message.user.reply_to]
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
  robot.adapter.driver.asyncCall 'getRoomIdByNameOrId', room
  .then (result) ->
    envelope = room: room
    robot.send envelope, message
    cb?()
  .catch (error) ->
    if error.error == 'error-not-allowed'
      job = JOBS[id]
      job.cancel()
      delete JOBS[id]
      delete robot.brain.get(STORE_KEY)[id]
      robot.logger.warning "#{id}: The schedule has been canceled because robot can not access the room."
