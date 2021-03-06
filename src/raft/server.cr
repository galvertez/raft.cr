require "socket"
require "openssl"

class Raft::Server
  # The PIN number of the server. Used in communication so that
  # peers know who is sending messages
  getter id : Int64

  # The address of the interface to use
  property paddr : Socket::IPAddress
  def paddr=(s : String)
    host, port = s.split(':', 2)
    if host && port
      host = Socket::Addrinfo.resolve(host)
      port = port.to_i
      @paddr = Socket::IPAddr.new(host, port)
    else
      raise "invalid address for peering listener"
    end
  end

  # The address for the application to use
  property aaddr : Socket::IPAddress
  def aaddr=(s : String)
    host, port = s.split(':', 2)
    if host && port
      host = Socket::Addrinfo.resolve(host)
      port = port.to_i
      @aaddr = Socket::IPAddress.ew(host, port)
    else
      raise "invalid address for application listener"
    end
  end

  # The `TCPServer` or `OpenSSL::SSL::Server` this `Raft::Server`
  # uses to listen for requests from peers
  #
  # It may be a mistake to keep this as an instance variable
  # rather than just generating it new on `Raft::Server#start`
  getter listener : Listener

  # List of remote peer `Raft::Server`s in the cluster
  getter peers : Hash(Int64, Peer) = {} of Int64 => Peer

  # The `@id` of the leading server or `nil` if this `Raft::Server` is leading
  getter following : Int64

  # The SSL context of this `Raft::Server`
  setter tls : OpenSSL::SSL::Context? = nil

  # Election timeout in milliseconds. The `Raft::Server` will initiate an
  # election if this timeout is reached
  property timeout : Int32

  @state : Raft::State = Raft::State.new

  delegate last_log_idx, last_log_term, to: @state

  def initialize(
      auth_key : Int64,
      paddr : String,
      aaddr : String,
      tls : OpenSSL::SSL::Context? = nil
      @timeout : Int32 = 300
    )

    self.paddr = paddr
    self.aaddr = aaddr

    # Before we start, we are "following" self
    @following = @id = Random.rand(Int64::MIN..Int64::MAX)
    @state = Raft::State.new

    listener = TCPServer.new(host, port)

    if tls
      @tls = tls
      @listener = Listener.new(OpenSSL::SSL::Server.new(listener, tls))
    else
      @listener = Listener.new(listener)
    end
  end

  def start
    # check for new connections
    loop do
      spawn do
        conns = @listener.check_new_conns
        if conns.any?
          remotes = @peers.map(&.socket.remote_address)
          conns.each do |conn|
            # this doesn't account for peers with dead
            # sockets, and also doesn't account for peers
            # who are tryng to reconnect - right now the way
            # `Peer#socket` works, is it will try to create a new
            # connection if the socket doesn't exist, or is closed
            # which means when a client loses a connectino and attempts
            # to reconnect here, calling `#socket` here will cause
            # this method to run on the remote peer as well, leading to
            # possibly both or neither server holding onto the connection
            remote = conn.remote_address
            next if remotes.include?(remote)

            # have to figure out how to create peer by reading the handshake
            # packet that will be coming through this socket. we need
            # the ID from that packet so we should probably expect
            # a `RPC::Handshake` and get the id that way. this might solve the
            # problem above too
            id = #something
            peer = Peer.new(remote.address, remote.port, id, @tls)
            @peers[id] = peer
          end
        end

        while leading?
          @peers.each do |id, peer|
            spawn { heartbeat(peer) }
          end

          # do the other stuff as a leader here
          # including check to see if we have
          # been usurped
        end

        # we leave the `while leading?` block
        # if we get demoted from leader
        # therefore now we are following

        if timeout_exceeded?
          @peers.each do |id, peer|
            spawn { request_vote(peer) }
          end
        end

        restart_clock
      end
    end

    sleep
  end

  # Campaigns for leadership with all active peers.
  # Yields if the quorum is met and election is won.
  # Otherwise returns `nil`
  def campaign : Nil
    # official raft specifications might say this only happens
    # after an election is won - will have to check, but i think
    # the incremented term number is what allows the peers
    # to vote yes
    @term += 1

    # this loop initiates the election.
    # we don't wait for the responses yet, as we want to send out all
    # ballots before we start tallying any of them.
    @peers.each do |id, peer|
      peer.send(RequestVote.new(@term, @id, last_log_idx, last_log_term))
    end

    # start with 1, as the vote for self
    tally = 0

    # this loop collects and tallies votes.
    # additionally, this loop can cancel the campaign at any time if
    # a peer responds with an `AppendEntries`, rather than a `RequestVote::Result`
    until votes >= quorum
      @peers.each do |id, peer|
        response = RPC::Packet.new(socket, NetworkFormat)
        case response
        when RPC::RequestVote::Result
          votes += 1 if response.vote_granted
        when RPC::AppendEntries
        when RPC::AppendEntries::Result
        when RPC::RequestVote
          # always vote `false` because we have voted for ourselves
          # in our own campaign
          response = RPC::RequestVote::Result.new(@term, false)
          peer.send(response)
        else
        end
      end
    end
  end

  def vote(req : RPC::ReqeuestVote)
    (@state.voted_for == nil) &&
    req.term >= @state.current_term
  end

  @[AlwaysInline]
  def quorum
    @peers.size / 2 + 1
  end

  def leading?
    @id == @following
  end

  # `following?` is used to determine whether or not to
  # change state.
  def following?
    @id != @following
  end

  def become_leader
    @following = @id
  end

  def connect_peer(addr : Socket::IPAddress)
    _tls = @tls
    if _tls
      peer = Raft::Peer.new(addr, port)
    else
      peer = Raft::Peer.new(addr, port, _tls)
    end

    peer.send(Raft::RPC::HandShake.new())
    result = peer.read()
  end
end

require "./server/listener"
