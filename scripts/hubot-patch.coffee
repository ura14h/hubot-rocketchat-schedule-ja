# Description:
#   Patch for the message response pattern of Hubot
#
# Author:
#   ura14h <ishiura@ja2.so-net.ne.jp>

module.exports = (robot) ->

  # Hacks the message response pattern in /node_modules/hubot/src/robot.js.
  # The robot will respond to only "BOT_NAME ..."
  robot.respondPattern = (regex) ->
    regexWithoutModifiers = regex.toString().split('/')
    regexWithoutModifiers.shift()
    modifiers = regexWithoutModifiers.pop()
    pattern = regexWithoutModifiers.join('/')
    name = this.name.replace(/[-[\]{}()*+?.,\\^$|#\s]/g, '\\$&')
    return new RegExp('^\\s*' + name + '\\s*(?:' + pattern + ')', modifiers)
