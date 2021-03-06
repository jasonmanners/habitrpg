_ = require('underscore')
character = require './character'
browser = require './browser'

partyUnsubscribe = (model, cb) ->
  if window?
    throw "unsubscribe requires cb" unless cb?
    subs = model._subs()
    subs.concat cb
    model.unsubscribe.apply(model, subs)
  else
    cb()

###
  Subscribe to the user, the users's party (meta info like party name, member ids, etc), and the party's members. 3 subscriptions.
  1) If the user is solo, just subscribe to the user.
  2) If in a an empty party, just subscribe to the user & party meta.
  3) If full party, subscribe to everything.
###
module.exports.partySubscribe = partySubscribe = (model, cb) ->

  # unsubscribe from everything - we're starting over
  # partyUnsubscribe model, ->

  # Restart subscription to the main user
  selfQ = model.query('users').withId(model.get('_userId') or model.session.userId)
  selfQ.subscribe (err, self) ->
    throw err if err
    u = self.at(0)
    uObj = u.get()

    ## (1) User is solo, just return that subscription
    unless uObj.party?.current?
      model.ref '_user', u
      return cb()

    ###
      Note this strange hack - we subscribe to queries incrementally. First self, then party, then party members.
      Party members come with limited fields, so you can't hack their stuff. Strangely, subscribing to the members after
      already subscribing to self limits self's fields to the fields which members are limited to. As a result, we have
      to re-subscribe to self to get all the fields (otherwise everything breaks). Weirdly, this last subscription doesn't
      do the opposite - granting all the fields back to members. I dont' know what's going on here

      Another issue: `model.unsubscribe(selfQ)` would seem to mitigate  the above, so we at least don't have a stray
      subscription floating around - but alas, it doesn't seem to work (or at least never calls the callback)
    ###
    finished = ->
      # model.unsubscribe selfQ, ->
      selfQ.subscribe (err, self) ->
        model.ref '_user', self.at(0)
        cb()

    # User in a party
    partiesQ = model.query('parties').withId(uObj.party.current)
    partiesQ.fetch (err, res) ->
      throw err if err
      p = res.at(0)
      model.ref '_party', p
      ids = p.get('members')

      # FIXME this is the kicker right here. This isn't getting triggered, and it's the reason why we have to refresh
      # after every event. Get this working
      #p.on '*', 'members', (ids) ->
      #  console.log("members listener got called")
      #  debugger
      #  membersSubscribe model, ids

      ## (2) Party has no members, just subscribe to the party itself
      if _.isEmpty(ids)
        return finished()

      else
        ## (3) Party has members, subscribe to those users too
        membersQ = model.query('users').party(ids)
        membersQ.fetch (err, members) ->
          throw err if err
          model.ref '_partyMembers', members
          finished()

module.exports.app = (appExports, model) ->
  user = model.at('_user')

  user.on 'set', 'flags.partyEnabled', (captures, args) ->
    return unless captures == true
    $('.main-avatar').popover('destroy') #remove previous popovers
    html = """
           <div class='party-system-popover'>
           <img src='/img/party-unlocked.png' style='float:right;padding:5px;' />
           Congratulations, you have unlocked the Party System! You can now group with your friends by adding their User Ids.
           <a href='#' onClick="$('.main-avatar').popover('hide');return false;">[Close]</a>
           </div>
           """
    $('.main-avatar').popover
      title: "Party System Unlocked"
      placement: 'bottom'
      trigger: 'manual'
      html: true
      content: html
    $('.main-avatar').popover 'show'

  model.on 'set', '_user.party.invitation', -> partySubscribe(model)

  appExports.partyCreate = ->
    newParty = model.get("_newParty")
    id = model.add 'parties', { name: newParty, leader: user.get('id'), members: [user.get('id')], invites:[] }
    user.set 'party', {current: id, invitation: null, leader: true}, ->
      window.location.reload true
#    partySubscribe model, -> $('#party-modal').modal('show')

  appExports.partyInvite = ->
    id = model.get('_newPartyMember').replace(/[\s"]/g, '')
    return if _.isEmpty(id)

    obj = user.get()
    query = model.query('users').party([id])
    model.fetch query, (err, res) ->
      throw err if err
      u = res.at(0).get()
      if !u?.id?
        model.set "_view.partyError", "User with id #{id} not found."
        return
      else if u.party.current? or u.party.invitation?
        model.set "_view.partyError", "User already in a party or pending invitation."
        return
      else
        p = model.at '_party'
        p.push "invites", id
        model.set "users.#{id}.party.invitation", p.get('id')
        $.bootstrapGrowl "Invitation Sent."
        $('#party-modal').modal('hide')
        model.set '_newPartyMember', '', -> window.location.reload true
        #partySubscribe model

  appExports.partyAccept = ->
    partyId = user.get('party.invitation')
    user.set 'party.invitation', null
    user.set 'party.current', partyId
#    model.push "parties.#{partyId}.members", user.get('id'), -> #FIXME why this not working?
    model.query('parties').withId(partyId).fetch (err, p) ->
      members = p.at(0).get('members')
      members.push user.get('id')
      p.at(0).set 'members', members, ->
        window.location.reload true
#    partySubscribe model, ->
#      p = model.at('_party')
#      p.push 'members', user.get('id')

  appExports.partyReject = ->
    user.set 'party.invitation', null
    browser.resetDom(model)
    # TODO splice parties.*.invites[key]
    # TODO notify sender

  appExports.partyLeave = ->
    id = user.set 'party.current', null
    p = model.at '_party'
    members = p.get('members')
    index = members.indexOf(user.get('id'))
    members.splice(index,1)
    p.set 'members', members, ->
      if (members.length == 0)
        # last member out, kill the party
        model.del "parties.#{id}", -> window.location.reload true
      else
        window.location.reload true
#    model.set '_party', null
#    model.set '_partyMembers', null
#    partyUnsubscribe model, ->
#      selfQ = model.query('users').withId(model.get('_userId') or model.session.userId)
#      selfQ.subscribe (err, u) ->
#        model.ref '_user', u.at(0)
#        browser.resetDom model